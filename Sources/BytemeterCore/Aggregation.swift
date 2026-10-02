import Foundation

public struct Totals: Equatable {
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    /// How much of `bytesIn` and `bytesOut` sits in minutes marked estimated.
    /// A part of the figures above, never an addition to them: the bytes are
    /// real and every total counts them, only their timing is spread.
    public let estimatedIn: UInt64
    public let estimatedOut: UInt64

    public init(bytesIn: UInt64 = 0, bytesOut: UInt64 = 0, estimatedIn: UInt64 = 0, estimatedOut: UInt64 = 0) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.estimatedIn = estimatedIn
        self.estimatedOut = estimatedOut
    }
    public var total: UInt64 { bytesIn &+ bytesOut }
    public var estimatedTotal: UInt64 { estimatedIn &+ estimatedOut }
    public var isEmpty: Bool { bytesIn == 0 && bytesOut == 0 }
    public static func + (a: Totals, b: Totals) -> Totals {
        Totals(bytesIn: a.bytesIn &+ b.bytesIn, bytesOut: a.bytesOut &+ b.bytesOut,
               estimatedIn: a.estimatedIn &+ b.estimatedIn, estimatedOut: a.estimatedOut &+ b.estimatedOut)
    }
}

public struct MinuteRow {
    public let minute: Int64
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public let idle: Bool
    public let estimatedIn: UInt64
    public let estimatedOut: UInt64

    public var totals: Totals {
        Totals(bytesIn: bytesIn, bytesOut: bytesOut, estimatedIn: estimatedIn, estimatedOut: estimatedOut)
    }
}

/// Everything counted since counting began, for the fourth menu bar position
/// and the dashboard. "All time" means since the earliest minute on record,
/// not since the Mac was new: what an interface had carried before it was
/// first seen has no timestamps and is deliberately never in `samples`.
public struct AllTimeSummary {
    public let totals: Totals
    /// The start of the earliest minute on record, or nil if nothing has been.
    public let since: Date?
    /// Days from `since` to now, with the fraction.
    public let days: Double
    public let perDay: Totals

    /// The day count as words, the same in the menu and on the dashboard.
    public var daysText: String {
        days < 1 ? "less than a day" : String(format: "%.1f days", days)
    }
}

public struct LabelledTotals {
    public let label: String
    public let date: Date
    public let totals: Totals
}

public struct TopTalker {
    public let name: String
    public let totals: Totals
}

public struct HeatCell {
    public let weekday: Int   // 0 is Monday
    public let hour: Int
    public let totals: Totals
}

/// Every figure in the app is derived from the `samples` table at query time,
/// so today, this week, this month and the averages can never disagree with
/// one another. Nothing is precomputed and cached.
public struct Aggregator {
    public let db: Database
    public let cal: BytemeterCalendar

    public init(db: Database, cal: BytemeterCalendar) {
        self.db = db
        self.cal = cal
    }

    // MARK: - Raw fetches

    public func totals(_ range: MinuteRange) -> Totals {
        var result = Totals()
        try? db.query("""
            SELECT COALESCE(SUM(bytes_in),0), COALESCE(SUM(bytes_out),0),
                   COALESCE(SUM(CASE WHEN estimated!=0 THEN bytes_in ELSE 0 END),0),
                   COALESCE(SUM(CASE WHEN estimated!=0 THEN bytes_out ELSE 0 END),0)
            FROM samples WHERE minute>=? AND minute<?;
            """, [.int(range.start), .int(range.end)]) { row in
            result = Totals(bytesIn: row.uint(0), bytesOut: row.uint(1),
                            estimatedIn: row.uint(2), estimatedOut: row.uint(3))
        }
        return result
    }

    public func minuteRows(_ range: MinuteRange) -> [MinuteRow] {
        var rows: [MinuteRow] = []
        try? db.query("""
            SELECT minute, SUM(bytes_in), SUM(bytes_out), MIN(idle),
                   SUM(CASE WHEN estimated!=0 THEN bytes_in ELSE 0 END),
                   SUM(CASE WHEN estimated!=0 THEN bytes_out ELSE 0 END)
            FROM samples WHERE minute>=? AND minute<? GROUP BY minute ORDER BY minute;
            """, [.int(range.start), .int(range.end)]) { row in
            rows.append(MinuteRow(minute: row.int(0), bytesIn: row.uint(1),
                                  bytesOut: row.uint(2), idle: row.int(3) == 1,
                                  estimatedIn: row.uint(4), estimatedOut: row.uint(5)))
        }
        return rows
    }

    public func earliestMinute() -> Int64? {
        var found: Int64?
        try? db.query("SELECT MIN(minute) FROM samples;") { row in
            let v = row.int(0)
            if v > 0 { found = v }
        }
        return found
    }

    // MARK: - Shaped views

    /// 24 buckets for one local day. Hours run 0 to 23 in local time.
    /// On the two clock change days a 23 or 25 hour day folds into the same 24
    /// slots; the daily total stays exact, only the hour split shifts.
    public func hourly(day: Date) -> [Totals] {
        let start = cal.startOfDay(day)
        let end = cal.addDays(1, to: start)
        let startMinute = BytemeterCalendar.minute(from: start)
        var buckets = [Totals](repeating: Totals(), count: 24)
        for row in minuteRows(cal.range(from: start, to: end)) {
            let index = Int(min(max((row.minute - startMinute) / 60, 0), 23))
            buckets[index] = buckets[index] + row.totals
        }
        return buckets
    }

    /// Daily totals for the last `count` days, oldest first, today last.
    public func daily(lastDays count: Int, now: Date) -> [LabelledTotals] {
        let firstDay = cal.addDays(-(count - 1), to: cal.startOfDay(now))
        let starts = cal.dayStarts(from: firstDay, dayCount: count)
        let endMinute = BytemeterCalendar.minute(from: now) + 1
        var buckets = [Totals](repeating: Totals(), count: count)

        for row in minuteRows(MinuteRange(start: starts[0], end: endMinute)) {
            guard let index = dayIndex(for: row.minute, in: starts) else { continue }
            buckets[index] = buckets[index] + row.totals
        }
        return (0..<count).map { index in
            let date = BytemeterCalendar.date(fromMinute: starts[index])
            return LabelledTotals(label: cal.dayLabel(date), date: date, totals: buckets[index])
        }
    }

    /// Weekday against hour. This is the view that shows when the data really goes.
    public func heatmap(lastDays count: Int, now: Date) -> [HeatCell] {
        let firstDay = cal.addDays(-(count - 1), to: cal.startOfDay(now))
        let starts = cal.dayStarts(from: firstDay, dayCount: count)
        let endMinute = BytemeterCalendar.minute(from: now) + 1
        var grid = [Totals](repeating: Totals(), count: 7 * 24)

        for row in minuteRows(MinuteRange(start: starts[0], end: endMinute)) {
            guard let index = dayIndex(for: row.minute, in: starts) else { continue }
            let date = BytemeterCalendar.date(fromMinute: starts[index])
            let weekday = mondayIndex(date)
            let hour = Int(min(max((row.minute - starts[index]) / 60, 0), 23))
            let slot = weekday * 24 + hour
            grid[slot] = grid[slot] + row.totals
        }
        return (0..<(7 * 24)).map { HeatCell(weekday: $0 / 24, hour: $0 % 24, totals: grid[$0]) }
    }

    /// One row per calendar month that has any data, oldest first.
    public func monthly(now: Date) -> [LabelledTotals] {
        guard let earliest = earliestMinute() else { return [] }
        var out: [LabelledTotals] = []
        var cursor = cal.startOfCycle(BytemeterCalendar.date(fromMinute: earliest))
        let limit = cal.endOfCycle(now)
        while cursor < limit {
            let next = cal.endOfCycle(cursor)
            let totals = totals(cal.range(from: cursor, to: next))
            out.append(LabelledTotals(label: cal.monthLabel(cursor), date: cursor, totals: totals))
            cursor = next
            if out.count > 120 { break }   // a decade is plenty of guard rail
        }
        return out
    }

    public func topTalkers(_ range: MinuteRange, limit: Int) -> [TopTalker] {
        var out: [TopTalker] = []
        try? db.query("""
            SELECT proc, SUM(bytes_in), SUM(bytes_out) FROM proc_samples
            WHERE minute>=? AND minute<? GROUP BY proc
            ORDER BY SUM(bytes_in)+SUM(bytes_out) DESC LIMIT ?;
            """, [.int(range.start), .int(range.end), .int(Int64(limit))]) { row in
            out.append(TopTalker(name: row.string(0),
                                 totals: Totals(bytesIn: row.uint(1), bytesOut: row.uint(2))))
        }
        return out
    }

    /// Idle against active. Idle means no keyboard or mouse input for five
    /// minutes when the bucket was written.
    public func idleSplit(_ range: MinuteRange) -> (idle: Totals, active: Totals) {
        var idle = Totals()
        var active = Totals()
        try? db.query("""
            SELECT idle, SUM(bytes_in), SUM(bytes_out) FROM samples
            WHERE minute>=? AND minute<? GROUP BY idle;
            """, [.int(range.start), .int(range.end)]) { row in
            let totals = Totals(bytesIn: row.uint(1), bytesOut: row.uint(2))
            if row.int(0) == 1 { idle = totals } else { active = totals }
        }
        return (idle, active)
    }

    public func byInterface(_ range: MinuteRange) -> [(String, Totals)] {
        var out: [(String, Totals)] = []
        try? db.query("""
            SELECT iface, SUM(bytes_in), SUM(bytes_out) FROM samples
            WHERE minute>=? AND minute<? GROUP BY iface ORDER BY SUM(bytes_in)+SUM(bytes_out) DESC;
            """, [.int(range.start), .int(range.end)]) { row in
            out.append((row.string(0), Totals(bytesIn: row.uint(1), bytesOut: row.uint(2))))
        }
        return out
    }

    public func bySSID(_ range: MinuteRange) -> [(String, Totals)] {
        var out: [(String, Totals)] = []
        try? db.query("""
            SELECT ssid, SUM(bytes_in), SUM(bytes_out) FROM samples
            WHERE minute>=? AND minute<? GROUP BY ssid ORDER BY SUM(bytes_in)+SUM(bytes_out) DESC;
            """, [.int(range.start), .int(range.end)]) { row in
            out.append((row.string(0), Totals(bytesIn: row.uint(1), bytesOut: row.uint(2))))
        }
        return out
    }

    // MARK: - Derived figures

    /// Average per hour so far today. Counts hours elapsed, not a flat 24, so
    /// the figure means something at 09:00 as well as at 23:00.
    public func averagePerHourToday(now: Date) -> Totals {
        let elapsed = max(1.0, now.timeIntervalSince(cal.startOfDay(now)) / 3600.0)
        return divide(totals(cal.today(now)), by: elapsed)
    }

    public func averagePerDay(_ range: MinuteRange, now: Date) -> Totals {
        let days = max(1.0, Double(range.minutes) / (60.0 * 24.0))
        return divide(totals(range), by: days)
    }

    /// Where this cycle lands if the rest of it looks like the days so far.
    public func projection(now: Date) -> (projected: Totals, cycleEnd: Date) {
        let start = cal.startOfCycle(now)
        let end = cal.endOfCycle(now)
        let elapsedDays = max(1.0, now.timeIntervalSince(start) / 86_400.0)
        let totalDays = max(elapsedDays, end.timeIntervalSince(start) / 86_400.0)
        let soFar = totals(cal.thisCycle(now))
        let factor = totalDays / elapsedDays
        return (Totals(bytesIn: UInt64(Double(soFar.bytesIn) * factor),
                       bytesOut: UInt64(Double(soFar.bytesOut) * factor)), end)
    }

    /// Every byte on record, from the earliest minute onwards. No upper
    /// bound: a row written while the clock was wrong still moved real data,
    /// and "all time" should not quietly drop it.
    public func allTime(now: Date) -> AllTimeSummary {
        guard let earliest = earliestMinute() else {
            return AllTimeSummary(totals: Totals(), since: nil, days: 0, perDay: Totals())
        }
        let totals = totals(MinuteRange(start: earliest, end: Int64.max))
        let since = BytemeterCalendar.date(fromMinute: earliest)
        let days = max(0, now.timeIntervalSince(since)) / 86_400.0
        // Under a day, the figure so far stands as the day's figure, the same
        // floor the other per day averages use.
        return AllTimeSummary(totals: totals, since: since, days: days, perDay: divide(totals, by: max(1.0, days)))
    }

    public func peakHourToday(now: Date) -> (hour: Int, totals: Totals)? {
        let buckets = hourly(day: now)
        guard let best = buckets.enumerated().max(by: { $0.element.total < $1.element.total }),
              best.element.total > 0 else { return nil }
        return (best.offset, best.element)
    }

    public func peakDayThisCycle(now: Date) -> LabelledTotals? {
        let start = cal.startOfCycle(now)
        let days = max(1, cal.calendar.dateComponents([.day], from: start, to: now).day.map { $0 + 1 } ?? 1)
        let series = daily(lastDays: days, now: now)
        guard let best = series.max(by: { $0.totals.total < $1.totals.total }),
              best.totals.total > 0 else { return nil }
        return best
    }

    // MARK: - Helpers

    private func divide(_ totals: Totals, by divisor: Double) -> Totals {
        guard divisor > 0 else { return Totals() }
        return Totals(bytesIn: UInt64(Double(totals.bytesIn) / divisor),
                      bytesOut: UInt64(Double(totals.bytesOut) / divisor))
    }

    /// Which day does this minute belong to, given local midnights.
    private func dayIndex(for minute: Int64, in starts: [Int64]) -> Int? {
        guard let first = starts.first, minute >= first else { return nil }
        var low = 0
        var high = starts.count - 1
        var answer = 0
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= minute { answer = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return answer
    }

    /// 0 is Monday, matching the house convention that the week starts Monday.
    private func mondayIndex(_ date: Date) -> Int {
        let weekday = cal.calendar.component(.weekday, from: date)   // 1 is Sunday
        return (weekday + 5) % 7
    }
}
