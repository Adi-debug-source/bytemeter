import Foundation

/// The daily tidy up. One minute buckets are roughly 500,000 rows a year, about
/// 25 MB, which is fine to keep; but past 90 days nobody needs minute detail, so
/// they are collapsed to hourly and the file stops growing linearly.
public enum Maintenance {

    public static let retainMinuteDays: Int64 = 90

    /// Collapse anything older than the cutoff into hourly buckets.
    ///
    /// Hours are UTC hour boundaries. Every UK offset is a whole number of
    /// hours from UTC, so a local hour and a UTC hour start at the same instant
    /// and no figure above the hour changes. Minute detail inside those old
    /// hours is the only thing lost, which is the point.
    ///
    /// One consequence worth knowing: a collapsed row sits at the start of its
    /// hour, so its bytes move backwards by up to 59 minutes. Every range the
    /// app asks for begins at local midnight, which is an hour boundary, so no
    /// figure on screen shifts. A hand written query starting mid-hour over
    /// pruned data is the only thing that would notice.
    ///
    /// A collapsed hour is marked estimated if any minute in it was, so the
    /// mark survives the tidy up the same way the bytes do.
    @discardableResult
    public static func prune(db: Database, now: Date = Date()) -> Int64 {
        let cutoff = BytemeterCalendar.minute(from: now) - retainMinuteDays * 24 * 60

        var pending: Int64 = 0
        try? db.query("SELECT COUNT(*) FROM samples WHERE minute<? AND minute%60!=0;",
                      [.int(cutoff)]) { pending = $0.int(0) }
        guard pending > 0 else { return 0 }

        db.transaction {
            try db.exec("DROP TABLE IF EXISTS rollup_samples;")
            try db.run("""
                CREATE TEMP TABLE rollup_samples AS
                SELECT (minute/60)*60 AS m, iface, ssid,
                       SUM(bytes_in) AS bi, SUM(bytes_out) AS bo, MIN(idle) AS idl,
                       MAX(estimated) AS est
                FROM samples WHERE minute<? GROUP BY m, iface, ssid;
                """, [.int(cutoff)])
            try db.run("DELETE FROM samples WHERE minute<?;", [.int(cutoff)])
            try db.exec("""
                INSERT INTO samples(minute,iface,ssid,bytes_in,bytes_out,idle,estimated)
                SELECT m, iface, ssid, bi, bo, idl, est FROM rollup_samples;
                """)
            try db.exec("DROP TABLE rollup_samples;")

            try db.exec("DROP TABLE IF EXISTS rollup_procs;")
            try db.run("""
                CREATE TEMP TABLE rollup_procs AS
                SELECT (minute/60)*60 AS m, proc,
                       SUM(bytes_in) AS bi, SUM(bytes_out) AS bo
                FROM proc_samples WHERE minute<? GROUP BY m, proc;
                """, [.int(cutoff)])
            try db.run("DELETE FROM proc_samples WHERE minute<?;", [.int(cutoff)])
            try db.exec("""
                INSERT INTO proc_samples(minute,proc,bytes_in,bytes_out)
                SELECT m, proc, bi, bo FROM rollup_procs;
                """)
            try db.exec("DROP TABLE rollup_procs;")
        }

        db.addEvent(ts: Int64(now.timeIntervalSince1970), kind: "prune",
                    detail: "Collapsed \(pending) minute buckets older than \(retainMinuteDays) days into hourly buckets.")
        return pending
    }
}
