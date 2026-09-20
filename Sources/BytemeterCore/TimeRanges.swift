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
/// here and converted, which keeps the app correct across British Summer Time.
public struct BytemeterCalendar {
    public var calendar: Calendar
    /// 1 means calendar months. Any other day is a custom billing cycle start.
    public var cycleStartDay: Int

    public init(timeZone: TimeZone = .current, cycleStartDay: Int = 1) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = 2      // Monday, per house convention
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

    public func endOfCycle(_ date: Date) -> Date {
        let start = startOfCycle(date)
        return calendar.date(byAdding: .month, value: 1, to: start) ?? start
    }

    public func range(from: Date, to: Date) -> MinuteRange {
        MinuteRange(start: Self.minute(from: from), end: Self.minute(from: to))
    }

    public func today(_ now: Date) -> MinuteRange {
        range(from: startOfDay(now), to: Self.date(fromMinute: Self.minute(from: now) + 1))
    }

    public func yesterday(_ now: Date) -> MinuteRange {
        let start = addDays(-1, to: startOfDay(now))
        return range(from: start, to: startOfDay(now))
    }

    public func thisWeek(_ now: Date) -> MinuteRange {
        range(from: startOfWeek(now), to: Self.date(fromMinute: Self.minute(from: now) + 1))
    }

    public func rollingDays(_ count: Int, now: Date) -> MinuteRange {
        let start = addDays(-(count - 1), to: startOfDay(now))
        return range(from: start, to: Self.date(fromMinute: Self.minute(from: now) + 1))
    }

    public func thisCycle(_ now: Date) -> MinuteRange {
        range(from: startOfCycle(now), to: Self.date(fromMinute: Self.minute(from: now) + 1))
    }

    /// Local midnight for each day in the range, as epoch minutes. Built with
    /// the calendar rather than by adding 1440, so a clock change does not
    /// shift every later day by an hour.
    public func dayStarts(from: Date, dayCount: Int) -> [Int64] {
        var out: [Int64] = []
        var cursor = startOfDay(from)
        for _ in 0..<dayCount {
            out.append(Self.minute(from: cursor))
            cursor = addDays(1, to: cursor)
        }
        return out
    }

    // MARK: - Formatting, British English, day first, 24 hour

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

    public static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
}
