import Foundation

/// Half open range of unix epoch minutes: start included, end excluded.
public struct MinuteRange: Equatable {
    public let start: Int64
    public let end: Int64
    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = max(start, end)
    }
    public var minutes: Int64 { end - start }
}

/// All the date arithmetic, in local time, with the week starting on Monday.
/// Buckets are stored as UTC epoch minutes, so every boundary is worked out
/// here and converted, which keeps every figure correct across daylight
/// saving changes in any time zone.
///
/// A rule for every day boundary in this file: work it out fresh from noon
/// on the day in question, never by stepping from one midnight to the next.
/// Where a clock change skips midnight (Santiago, Cairo, Havana and others
/// move at 00:00) that day starts at 01:00, and a day added to 01:00 is
/// 01:00 the next day too, which would carry the hour into every later day.
/// Noon is never skipped.
public struct BytemeterCalendar {
    public var calendar: Calendar
    /// 1 means calendar months. Any other day is a custom billing cycle start.
    public var cycleStartDay: Int

    public init(timeZone: TimeZone = .current, cycleStartDay: Int = 1) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        // Weeks start on Monday and follow ISO 8601 week numbering, whatever
        // the region setting, so "this week" means the same on every Mac.
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        self.calendar = cal
        self.cycleStartDay = min(max(cycleStartDay, 1), 28)
    }

    public static func minute(from date: Date) -> Int64 {
        Ledger.floorDiv(Int64(date.timeIntervalSince1970.rounded(.down)), 60)
    }

    public static func date(fromMinute minute: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(minute * 60))
    }

    public func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    /// The start of the day `days` after the one holding `date` (before it,
    /// if negative). Midnight, or the first moment of that day where a clock
    /// change skips midnight. Worked out from noon; see the note above.
    public func startOfDay(_ date: Date, offsetBy days: Int) -> Date {
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        return startOfDay(calendar.date(byAdding: .day, value: days, to: noon) ?? noon)
    }

    /// Calendar days from the day holding `from` to the day holding `to`.
    public func daysBetween(_ from: Date, _ to: Date) -> Int {
        let a = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: from) ?? from
        let b = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: to) ?? to
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    /// The local hour, 0 to 23, of an epoch minute, from the calendar. The
    /// minutes since midnight divided by 60 would be an hour out for the rest
    /// of any day the clocks change.
    public func hour(ofMinute minute: Int64) -> Int {
        calendar.component(.hour, from: Self.date(fromMinute: minute))
    }

    /// Adds calendar days to an instant, keeping its wall clock time where it
    /// exists. Not for day boundaries: use `startOfDay(_:offsetBy:)`.
    public func addDays(_ count: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: count, to: date) ?? date
    }

    public func startOfWeek(_ date: Date) -> Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components) ?? startOfDay(date)
    }

    /// Start of the current billing cycle. With cycleStartDay 1 this is simply
    /// the first of the calendar month, which is the default.
    public func startOfCycle(_ date: Date) -> Date {
        let day = calendar.component(.day, from: date)
        var components = calendar.dateComponents([.year, .month], from: date)
        components.day = cycleStartDay
        guard var start = calendar.date(from: components) else { return startOfDay(date) }
        if day < cycleStartDay {
            start = calendar.date(byAdding: .month, value: -1, to: start) ?? start
        }
        return startOfDay(start)
    }

    /// The start of the next cycle. A month added to noon on the first day,
    /// then taken back to that day's start, for the same reason as the days.
    public func endOfCycle(_ date: Date) -> Date {
        let start = startOfCycle(date)
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: start) ?? start
        return startOfDay(calendar.date(byAdding: .month, value: 1, to: noon) ?? noon)
    }

    public func range(from: Date, to: Date) -> MinuteRange {
        MinuteRange(start: Self.minute(from: from), end: Self.minute(from: to))
    }

    public func today(_ now: Date) -> MinuteRange {
        range(from: startOfDay(now), to: Self.date(fromMinute: Self.minute(from: now) + 1))
    }

    public func yesterday(_ now: Date) -> MinuteRange {
        range(from: startOfDay(now, offsetBy: -1), to: startOfDay(now))
    }

    public func thisWeek(_ now: Date) -> MinuteRange {
        range(from: startOfWeek(now), to: Self.date(fromMinute: Self.minute(from: now) + 1))
    }

    public func rollingDays(_ count: Int, now: Date) -> MinuteRange {
        let start = startOfDay(now, offsetBy: -(count - 1))
        return range(from: start, to: Self.date(fromMinute: Self.minute(from: now) + 1))
    }

    public func thisCycle(_ now: Date) -> MinuteRange {
        range(from: startOfCycle(now), to: Self.date(fromMinute: Self.minute(from: now) + 1))
    }

    /// The start of each of `dayCount` days from the one holding `from`, as
    /// epoch minutes. Each is worked out on its own from noon, neither by
    /// adding 1440 minutes, which a clock change breaks, nor by stepping from
    /// the previous start, which a skipped midnight breaks.
    public func dayStarts(from: Date, dayCount: Int) -> [Int64] {
        (0..<max(0, dayCount)).map { Self.minute(from: startOfDay(from, offsetBy: $0)) }
    }

    // MARK: - Formatting: day first and 24 hour, whatever the region setting

    public func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }

    public func fullDayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEEE d MMMM yyyy"
        return f.string(from: date)
    }

    /// "20 Sep 2026": short, day first, with the year, for a start date that
    /// may be in an earlier year than the one on screen.
    public func dateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM yyyy"
        return f.string(from: date)
    }

    public func monthLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "MMM yyyy"
        return f.string(from: date)
    }

    public func timestampLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM yyyy 'at' HH:mm"
        return f.string(from: date)
    }

    /// "This month, from 1 Oct", or "This cycle, from 15 Sep" on a billing
    /// cycle. Saying where it starts is what tells it apart from the rolling
    /// "Last 30 days" figure beside it, the same way the week says "from Monday".
    public func cycleLabel(_ now: Date) -> String {
        (cycleStartDay == 1 ? "This month" : "This cycle") + ", from " + dayLabel(startOfCycle(now))
    }

    /// A local date and time as typed on the command line: ISO 8601 with no
    /// zone, "2026-10-02T21:30", seconds optional, read in this calendar's
    /// time zone. Nil for anything else, rather than a guess.
    public func parseLocal(_ text: String) -> Date? {
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = Locale(identifier: "en_US_POSIX")
            f.isLenient = false
            f.dateFormat = format
            if let date = f.date(from: text) { return date }
        }
        return nil
    }

    public static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
}
