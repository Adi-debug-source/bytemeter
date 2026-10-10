import Foundation

public struct Totals: Equatable {
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    /// How much of `bytesIn` and `bytesOut` is estimated: traffic from a
    /// stretch nobody watched, such as a sleep, booked to minutes by rule
    /// rather than measured in them. A part of the figures above, never an
    /// addition to them: the bytes are real and every total counts them,
    /// only their timing is estimated.
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
    /// Each of the four figures divided by `count`, rounded down, or empty
    /// when `count` is not above zero: an average over a number of days.
    public func divided(by count: Int) -> Totals {
        guard count > 0 else { return Totals() }
        let n = UInt64(count)
        return Totals(bytesIn: bytesIn / n, bytesOut: bytesOut / n,
                      estimatedIn: estimatedIn / n, estimatedOut: estimatedOut / n)
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

public struct HeatCell: Equatable {
    public let weekday: Int   // 0 is Monday
    public let hour: Int
    /// The sum over the counted days.
    public let totals: Totals
    /// How many of this weekday were counted, from 0 to the weeks asked for.
    public let days: Int
    /// The hour's traffic on an average counted day, or empty if none was.
    public var average: Totals { totals.divided(by: days) }
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
                   COALESCE(SUM(est_in),0), COALESCE(SUM(est_out),0)
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
            SELECT minute, SUM(bytes_in), SUM(bytes_out), MIN(idle), SUM(est_in), SUM(est_out)
            FROM samples WHERE minute>=? AND minute<? GROUP BY minute ORDER BY minute;
            """, [.int(range.start), .int(range.end)]) { row in
            rows.append(MinuteRow(minute: row.int(0), bytesIn: row.uint(1),
                                  bytesOut: row.uint(2), idle: row.int(3) == 1,
                                  estimatedIn: row.uint(4), estimatedOut: row.uint(5)))
        }
        return rows
    }

    public func earliestMinute() -> Int64? {
        earliestMinute(in: MinuteRange(start: 1, end: Int64.max))
    }

    /// The earliest minute on record inside a range, or nil if it holds none.
    public func earliestMinute(in range: MinuteRange) -> Int64? {
        var found: Int64?
        try? db.query("SELECT MIN(minute) FROM samples WHERE minute>=? AND minute<?;",
                      [.int(max(1, range.start)), .int(range.end)]) { row in
            let v = row.int(0)
            if v > 0 { found = v }
        }
        return found
    }

    // MARK: - Shaped views

    /// 24 buckets for one local day. Hours run 0 to 23 in local time, each
    /// row going to the hour the clock on the wall showed, from the calendar.
    /// On a clock change day that is the only right answer: on the day the
    /// clocks go back, 01:00 happens twice and both land in the 01:00 slot,
    /// and on the day they go forward the skipped hour's slot is empty.
    /// Nothing after `now` is counted, so a page drawn as of an earlier moment
    /// shows that moment's day, not the rest of it.
    public func hourly(day: Date, now: Date) -> [Totals] {
        let dayRange = cal.range(from: cal.startOfDay(day), to: cal.startOfDay(day, offsetBy: 1))
        var buckets = [Totals](repeating: Totals(), count: 24)
        for row in minuteRows(MinuteRange(start: dayRange.start, end: min(dayRange.end, endMinute(now)))) {
            let index = min(max(cal.hour(ofMinute: row.minute), 0), 23)
            buckets[index] = buckets[index] + row.totals
        }
        return buckets
    }

    /// Daily totals for the last `count` days, oldest first, today last.
    public func daily(lastDays count: Int, now: Date) -> [LabelledTotals] {
        guard count > 0 else { return [] }
        let starts = cal.dayStarts(from: cal.startOfDay(now, offsetBy: -(count - 1)), dayCount: count)
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

    /// Weekday against hour, as an average over the last `weeks` whole weeks.
    /// This is the view that shows when the data really goes.
    ///
    /// Whole weeks, so every weekday is counted as often as every other: 30
    /// days held two weekdays five times and the rest four, and the colours
    /// made those rows look busier than they were. The window is the
    /// `7 * weeks` whole days before today. Today is left out because it is
    /// not over. A day counts only if counting had begun by its start, so a
    /// new install's average is over the days it measured, not diluted by
    /// days it never saw; rows in a day that does not count are ignored.
    public func heatmap(weeks: Int = 4, now: Date) -> [HeatCell] {
        var grid = [Totals](repeating: Totals(), count: 7 * 24)
        var counted = [Int](repeating: 0, count: 7)
        let dayCount = 7 * max(0, weeks)
        let starts = cal.dayStarts(from: cal.startOfDay(now, offsetBy: -dayCount), dayCount: dayCount)
        // Rows after `now` are ignored here too, so the page as of an earlier
        // moment counts the days that moment would have.
        if let first = earliestMinute(in: MinuteRange(start: 1, end: endMinute(now))),
           let firstCounted = starts.firstIndex(where: { $0 >= first }) {
            for start in starts[firstCounted...] {
                counted[mondayIndex(BytemeterCalendar.date(fromMinute: start))] += 1
            }
            let today = BytemeterCalendar.minute(from: cal.startOfDay(now))
            for row in minuteRows(MinuteRange(start: starts[firstCounted], end: today)) {
                guard let index = dayIndex(for: row.minute, in: starts) else { continue }
                let weekday = mondayIndex(BytemeterCalendar.date(fromMinute: starts[index]))
                let hour = min(max(cal.hour(ofMinute: row.minute), 0), 23)   // the wall clock hour, as in `hourly`
                let slot = weekday * 24 + hour
                grid[slot] = grid[slot] + row.totals
            }
        }
        return (0..<(7 * 24)).map {
            HeatCell(weekday: $0 / 24, hour: $0 % 24, totals: grid[$0], days: counted[$0 / 24])
        }
    }

    /// The most months `monthly` lists: a decade.
    public static let maxMonths = 120

    /// One row per month (or billing cycle) from the first with any data to
    /// the current one, oldest first, empty months between included. Never
    /// more than `maxMonths`, and the newest are the ones kept: a stray row
    /// years in the past, from a clock that was wrong for a moment, must not
    /// push the current month off the end.
    public func monthly(now: Date) -> [LabelledTotals] {
        let current = cal.startOfCycle(now)
        let oldestNoon = cal.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: current) ?? current
        let oldest = cal.startOfCycle(
            cal.calendar.date(byAdding: .month, value: -(Self.maxMonths - 1), to: oldestNoon) ?? oldestNoon)
        guard let earliest = earliestMinute(in: MinuteRange(start: BytemeterCalendar.minute(from: oldest),
                                                            end: endMinute(now))) else { return [] }
        var out: [LabelledTotals] = []
        var cursor = cal.startOfCycle(BytemeterCalendar.date(fromMinute: earliest))
        let limit = cal.endOfCycle(now)
        while cursor < limit && out.count < Self.maxMonths {
            let next = cal.endOfCycle(cursor)
            let month = cal.range(from: cursor, to: next)
            let totals = totals(MinuteRange(start: month.start, end: min(month.end, endMinute(now))))
            out.append(LabelledTotals(label: cal.monthLabel(cursor), date: cursor, totals: totals))
            cursor = next
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

    /// When counting began within a period: the period's start, or the
    /// earliest minute on record if that is later. Every average and the
    /// projection divide by the time since this, not since the period
    /// began, or a Mac counting since Tuesday would have its traffic spread
    /// over a week it never measured. In the first month of a new install
    /// that made the month's daily average and the projection read a
    /// fraction of what they should. Rows after `now` are ignored, so a
    /// figure asked as of an earlier moment gets that moment's answer.
    public func countingStart(from periodStart: Date, now: Date) -> Date {
        let start = BytemeterCalendar.minute(from: periodStart)
        guard let first = earliestMinute(in: MinuteRange(start: 1, end: endMinute(now))), first > start else {
            return periodStart
        }
        return BytemeterCalendar.date(fromMinute: first)
    }

    /// Average per hour so far today, over the hours counted: since midnight,
    /// or since counting began if that was later today. Not a flat 24, so the
    /// figure means something at 09:00 as well as at 23:00.
    public func averagePerHourToday(now: Date) -> Totals {
        let elapsed = max(1.0, now.timeIntervalSince(countingStart(from: cal.startOfDay(now), now: now)) / 3600.0)
        return divide(totals(cal.today(now)), by: elapsed)
    }

    /// Average per day over a range ending now, such as this week or this
    /// month, over the days counted: from the range's start, or from when
    /// counting began if that was later.
    public func averagePerDay(_ range: MinuteRange, now: Date) -> Totals {
        let start = BytemeterCalendar.minute(from: countingStart(from: BytemeterCalendar.date(fromMinute: range.start),
                                                                 now: now))
        let days = max(1.0, Double(max(0, range.end - start)) / (60.0 * 24.0))
        return divide(totals(range), by: days)
    }

    /// Where this cycle lands if the rest of it goes on as it has, or nil
    /// when it is too early to say. The menu and the dashboard both use this
    /// one function. There are three cases:
    ///
    /// 1. A day or more counted this cycle, from the cycle's start or from
    ///    when counting began, whichever is later: the cycle so far, scaled
    ///    up by the days in the cycle over the days counted.
    /// 2. Under a day counted this cycle, but a whole day on record before
    ///    now, as on the morning of the 1st: the cycle so far, plus the last
    ///    24 hours' rate run on to the cycle's end. Scaling a few hours up as
    ///    if they were a whole day read a fraction of the real rate. The
    ///    trailing day keeps the figure continuous, because at exactly one
    ///    day counted both rules give the same answer.
    /// 3. Under a day on record at all, a new install, or nothing: nil. A few
    ///    hours of one day say too little about a month.
    ///
    /// Rows after `now` are ignored, so it can be asked as of an earlier moment.
    public func projection(now: Date) -> (projected: Totals?, cycleEnd: Date) {
        let end = cal.endOfCycle(now)
        guard let first = earliestMinute(in: MinuteRange(start: 1, end: endMinute(now))) else { return (nil, end) }
        let start = countingStart(from: cal.startOfCycle(now), now: now)
        let soFar = totals(cal.thisCycle(now))
        let elapsed = now.timeIntervalSince(start)

        if elapsed >= 86_400 {
            let elapsedDays = elapsed / 86_400.0
            let totalDays = max(elapsedDays, end.timeIntervalSince(start) / 86_400.0)
            let factor = totalDays / elapsedDays
            return (Totals(bytesIn: Self.clampedBytes(Double(soFar.bytesIn) * factor),
                           bytesOut: Self.clampedBytes(Double(soFar.bytesOut) * factor)), end)
        }

        let current = BytemeterCalendar.minute(from: now)
        guard first <= current - 1_439 else { return (nil, end) }
        let lastDay = totals(MinuteRange(start: current - 1_439, end: current + 1))
        let remaining = Double(max(0, BytemeterCalendar.minute(from: end) - (current + 1)))
        func run(_ soFar: UInt64, _ lastDay: UInt64) -> UInt64 {
            Self.clampedBytes(Double(soFar) + Double(lastDay) / 1_440.0 * remaining)
        }
        return (Totals(bytesIn: run(soFar.bytesIn, lastDay.bytesIn),
                       bytesOut: run(soFar.bytesOut, lastDay.bytesOut)), end)
    }

    /// The seven day average of download for each day of a `daily` series,
    /// or nil where there is none. A point is the mean of seven whole counted
    /// days ending on its own day: counting had begun by the start of each,
    /// and each is over, which leaves out the series' last day, today.
    /// Dividing by seven regardless counted the days before a new install as
    /// nothing, which drew a rising trend that was not there, and today's
    /// part day as a whole one, which pulled the end of every line down.
    public func sevenDayAverage(_ series: [LabelledTotals], now: Date) -> [Double?] {
        let first = earliestMinute(in: MinuteRange(start: 1, end: endMinute(now)))
        let whole = series.indices.map { index in
            guard let first, index < series.count - 1 else { return false }
            return first <= BytemeterCalendar.minute(from: series[index].date)
        }
        return series.indices.map { index in
            guard index >= 6, whole[(index - 6)...index].allSatisfy({ $0 }) else { return nil }
            return series[(index - 6)...index].reduce(0.0) { $0 + Double($1.totals.bytesIn) } / 7.0
        }
    }

    /// Every byte on record from the earliest minute up to and including the
    /// current one, so that, like every other figure, it can be asked as of
    /// an earlier moment.
    public func allTime(now: Date) -> AllTimeSummary {
        guard let earliest = earliestMinute(), earliest < endMinute(now) else {
            return AllTimeSummary(totals: Totals(), since: nil, days: 0, perDay: Totals())
        }
        let totals = totals(MinuteRange(start: earliest, end: endMinute(now)))
        let since = BytemeterCalendar.date(fromMinute: earliest)
        let days = max(0, now.timeIntervalSince(since)) / 86_400.0
        // Under a day, the figure so far stands as the day's figure, the same
        // floor the other per day averages use.
        return AllTimeSummary(totals: totals, since: since, days: days, perDay: divide(totals, by: max(1.0, days)))
    }

    /// The hour today with the most downloaded. Download only, the figure
    /// every headline uses, so a heavy upload cannot make an hour the peak
    /// and then be shown as a download figure it never had.
    public func peakDownloadHourToday(now: Date) -> (hour: Int, totals: Totals)? {
        let buckets = hourly(day: now, now: now)
        guard let best = buckets.enumerated().max(by: { $0.element.bytesIn < $1.element.bytesIn }),
              best.element.bytesIn > 0 else { return nil }
        return (best.offset, best.element)
    }

    /// The day so far this month, or this billing cycle, with the most downloaded.
    public func peakDownloadDayThisCycle(now: Date) -> LabelledTotals? {
        // Calendar days, counted noon to noon, so a cycle that began on a
        // skipped midnight (01:00) still counts its first day.
        let days = max(1, cal.daysBetween(cal.startOfCycle(now), now) + 1)
        let series = daily(lastDays: days, now: now)
        guard let best = series.max(by: { $0.totals.bytesIn < $1.totals.bytesIn }),
              best.totals.bytesIn > 0 else { return nil }
        return best
    }

    public func peakHourToday(now: Date) -> (hour: Int, totals: Totals)? {
        let buckets = hourly(day: now, now: now)
        guard let best = buckets.enumerated().max(by: { $0.element.total < $1.element.total }),
              best.element.total > 0 else { return nil }
        return (best.offset, best.element)
    }

    public func peakDayThisCycle(now: Date) -> LabelledTotals? {
        let days = max(1, cal.daysBetween(cal.startOfCycle(now), now) + 1)
        let series = daily(lastDays: days, now: now)
        guard let best = series.max(by: { $0.totals.total < $1.totals.total }),
              best.totals.total > 0 else { return nil }
        return best
    }

    // MARK: - Helpers

    /// The first minute after `now`: every range in this file ends here at
    /// the latest, so nothing later than the moment asked about is counted.
    private func endMinute(_ now: Date) -> Int64 { BytemeterCalendar.minute(from: now) + 1 }

    private func divide(_ totals: Totals, by divisor: Double) -> Totals {
        guard divisor > 0 else { return Totals() }
        return Totals(bytesIn: Self.clampedBytes(Double(totals.bytesIn) / divisor),
                      bytesOut: Self.clampedBytes(Double(totals.bytesOut) / divisor))
    }

    /// A Double as bytes. `UInt64(_:)` traps on NaN, on a negative value and
    /// on anything from 2^64 up, which includes `Double(UInt64.max)` itself,
    /// so the conversion is clamped rather than trusted.
    static func clampedBytes(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        return value >= 0x1p64 ? UInt64.max : UInt64(value)    // 0x1p64 is 2^64 exactly
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

    /// 0 is Monday: weeks start on Monday, as in ISO 8601, whatever the region setting.
    private func mondayIndex(_ date: Date) -> Int {
        let weekday = cal.calendar.component(.weekday, from: date)   // 1 is Sunday
        return (weekday + 5) % 7
    }
}
