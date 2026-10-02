import Foundation

/// The daily tidy up. One minute buckets are roughly 500,000 rows a year, about
/// 25 MB, which is fine to keep; but past 90 days nobody needs minute detail, so
/// they are collapsed to hourly and the file stops growing linearly.
public enum Maintenance {

    public static let retainMinuteDays: Int64 = 90

    /// Run the tidy up if the last one was more than a day ago, or if the
    /// clock now reads earlier than it. Returns the minute rows collapsed, or
    /// nil if it was not due. `last_maintenance` is written in the same
    /// transaction as the prune, so a prune that rolled back is tried again
    /// at the next check instead of being recorded as done.
    @discardableResult
    public static func runIfDue(db: Database, now: Date = Date(), timeZone: TimeZone = .current) throws -> Int64? {
        let nowSeconds = Int64(now.timeIntervalSince1970)
        let last = db.number(StateKey.lastMaintenance, default: 0)
        guard last > nowSeconds || Ledger.clampedElapsed(since: last, now: nowSeconds) > 24 * 3600 else { return nil }
        return try prune(db: db, now: now, timeZone: timeZone, markRun: true)
    }

    /// Collapse minute rows older than the cutoff into one row per local hour.
    ///
    /// Local hours, not UTC hours. In a zone whose offset is not a whole
    /// number of hours (India, Iran, Nepal, Newfoundland, South Australia
    /// and others) a UTC hour straddles two local hours, and on the hour
    /// that holds local midnight, two days: collapsing onto UTC hours would
    /// move 00:00 to 00:29 into the day before. So each row goes to the start
    /// of the local hour it is in, worked out from the zone's offset at that
    /// minute.
    ///
    /// The offset changes at a clock change, so the rows are taken in
    /// stretches between changes, each with its own offset. An hour start is
    /// never earlier than the change before it. That matters on Lord Howe
    /// Island, whose clocks move by 30 minutes: on the change day one local
    /// hour begins at the change itself, half way through a UTC hour, and
    /// without the limit its rows would be moved back into the hour before.
    ///
    /// The cutoff itself is moved back to the start of its local hour, so an
    /// hour is never left half collapsed. A collapsed row sits at the start
    /// of its hour, so its bytes move back by up to 59 minutes, never across
    /// a local hour and so never across a day, a week or a month. Minute
    /// detail inside those old hours is the only thing lost, which is the
    /// point. A collapsed hour is marked estimated if any minute in it was.
    ///
    /// Rows already at the start of their hour are left alone, so running
    /// it twice collapses nothing the second time. Everything it changes,
    /// and its event, commits together or not at all; a failure is thrown.
    @discardableResult
    public static func prune(db: Database, now: Date = Date(), timeZone: TimeZone = .current) throws -> Int64 {
        try prune(db: db, now: now, timeZone: timeZone, markRun: false)
    }

    private static func prune(db: Database, now: Date, timeZone: TimeZone, markRun: Bool) throws -> Int64 {
        let stamp = { try db.writeState(StateKey.lastMaintenance, String(Int64(now.timeIntervalSince1970))) }
        let rawCutoff = BytemeterCalendar.minute(from: now) - retainMinuteDays * 24 * 60

        var earliest: Int64?
        for table in ["samples", "proc_samples"] {
            try db.query("SELECT MIN(minute) FROM \(table) WHERE minute<?;", [.int(rawCutoff)]) { row in
                if row.isNotNull(0) { earliest = min(earliest ?? .max, row.int(0)) }
            }
        }
        guard let first = earliest else {
            if markRun { try stamp() }
            return 0
        }

        let stretches = offsetStretches(timeZone, from: first > Int64.min + 60 ? first - 60 : first, to: rawCutoff + 1)
        let cutoff = hourStart(of: rawCutoff, in: stretches)
        let start = hourStartSQL(stretches)

        var pending: Int64 = 0
        var pendingProcs: Int64 = 0
        var rewriteFrom: Int64 = .max
        for table in ["samples", "proc_samples"] {
            try db.query("SELECT COUNT(*), MIN(\(start)) FROM \(table) WHERE minute<? AND minute!=\(start);",
                         [.int(cutoff)]) { row in
                if table == "samples" { pending = row.int(0) } else { pendingProcs = row.int(0) }
                if row.int(0) > 0 { rewriteFrom = min(rewriteFrom, row.int(1)) }
            }
        }
        guard pending > 0 || pendingProcs > 0 else {
            if markRun { try stamp() }
            return 0
        }

        try db.inTransaction {
            let range: [Binding] = [.int(rewriteFrom), .int(cutoff)]
            try db.exec("DROP TABLE IF EXISTS rollup_samples;")
            try db.run("""
                CREATE TEMP TABLE rollup_samples AS
                SELECT \(start) AS m, iface, ssid,
                       SUM(bytes_in) AS bi, SUM(bytes_out) AS bo, MIN(idle) AS idl,
                       MAX(estimated) AS est
                FROM samples WHERE minute>=? AND minute<? GROUP BY m, iface, ssid;
                """, range)
            try db.run("DELETE FROM samples WHERE minute>=? AND minute<?;", range)
            try db.exec("""
                INSERT INTO samples(minute,iface,ssid,bytes_in,bytes_out,idle,estimated)
                SELECT m, iface, ssid, bi, bo, idl, est FROM rollup_samples;
                """)
            try db.exec("DROP TABLE rollup_samples;")

            try db.exec("DROP TABLE IF EXISTS rollup_procs;")
            try db.run("""
                CREATE TEMP TABLE rollup_procs AS
                SELECT \(start) AS m, proc,
                       SUM(bytes_in) AS bi, SUM(bytes_out) AS bo
                FROM proc_samples WHERE minute>=? AND minute<? GROUP BY m, proc;
                """, range)
            try db.run("DELETE FROM proc_samples WHERE minute>=? AND minute<?;", range)
            try db.exec("""
                INSERT INTO proc_samples(minute,proc,bytes_in,bytes_out)
                SELECT m, proc, bi, bo FROM rollup_procs;
                """)
            try db.exec("DROP TABLE rollup_procs;")

            try db.writeEvents([LedgerEvent(
                ts: Int64(now.timeIntervalSince1970), kind: "prune",
                detail: "Collapsed \(pending) minute buckets and \(pendingProcs) per-app rows older than "
                      + "\(retainMinuteDays) days into hourly buckets, on the local hours of \(timeZone.identifier).")])
            if markRun { try stamp() }
        }
        return pending
    }

    // MARK: - Local hours

    /// A run of minutes, `start` included and `end` not, over which the zone's
    /// offset from UTC, in minutes, does not change.
    struct OffsetStretch {
        let start: Int64
        let end: Int64
        let offset: Int64
    }

    /// The stretches covering `from` to `to`, split at every change of offset.
    /// Foundation's transition list includes changes that are not daylight
    /// saving, such as Moscow's in 2014 and Samoa's in 2011.
    static func offsetStretches(_ zone: TimeZone, from: Int64, to: Int64) -> [OffsetStretch] {
        var out: [OffsetStretch] = []
        var start = from
        while start < to {
            let date = BytemeterCalendar.date(fromMinute: start)
            let offset = Ledger.floorDiv(Int64(zone.secondsFromGMT(for: date)), 60)
            var end = to
            if let next = zone.nextDaylightSavingTimeTransition(after: date) {
                let seconds = Int64(next.timeIntervalSince1970.rounded(.up))
                let minute = -Ledger.floorDiv(-seconds, 60)          // rounded up to a whole minute
                if minute > start && minute < end { end = minute }
            }
            out.append(OffsetStretch(start: start, end: end, offset: offset))
            start = end
        }
        return out
    }

    /// The start of the local hour holding `minute`, the same rule as the SQL.
    static func hourStart(of minute: Int64, in stretches: [OffsetStretch]) -> Int64 {
        guard let stretch = stretches.first(where: { minute >= $0.start && minute < $0.end }) else { return minute }
        let intoHour = ((minute + stretch.offset) % 60 + 60) % 60
        return max(stretch.start, minute - intoHour)
    }

    /// The same rule as SQL over the `minute` column. Every value in it is an
    /// integer worked out here, never text from outside. SQLite's `%` keeps
    /// the sign of the left side, hence the `+ 60` and second `% 60`.
    static func hourStartSQL(_ stretches: [OffsetStretch]) -> String {
        let branches = stretches.map {
            "WHEN minute<\($0.end) THEN MAX(\($0.start), minute-(((minute+\($0.offset))%60)+60)%60)"
        }
        return "(CASE " + branches.joined(separator: " ") + " ELSE minute END)"
    }

}
