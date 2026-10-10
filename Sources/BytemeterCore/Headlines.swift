import Foundation

/// The headline figures, worked out in one place for everything that shows
/// them: the menu, the dashboard, and the menu bar figure, which is one of
/// them. The menu and the dashboard each used to run the same queries for
/// themselves, so only care kept the two in step.
///
/// Like every figure, they are read from `samples` when asked, as of `now`.
public struct Headlines {
    public let today: Totals
    public let yesterday: Totals
    public let thisWeek: Totals
    public let last7: Totals
    /// This month, or this billing cycle when one starts on another day.
    public let thisMonth: Totals
    public let last30: Totals
    public let allTime: AllTimeSummary
    /// Where this month or cycle is heading, download and upload together,
    /// or nil when it is too early to say.
    public let projected: Totals?
    /// The projection worded once, for the menu and the dashboard alike.
    public let projection: ProjectionWording
    /// The hour today and the day this month or cycle with the most
    /// downloaded, or nil before there is any. Download only, like every
    /// headline figure, so the peak day can never read larger than the month
    /// printed above it.
    public let peakHour: (hour: Int, totals: Totals)?
    public let peakDay: LabelledTotals?

    /// `now` is the moment the figures describe: the clock for the real app,
    /// or a fixed moment for a page drawn as of a time, a demo or a test.
    public init(aggregator: Aggregator, now: Date) {
        let cal = aggregator.cal
        today = aggregator.totals(cal.today(now))
        yesterday = aggregator.totals(cal.yesterday(now))
        thisWeek = aggregator.totals(cal.thisWeek(now))
        last7 = aggregator.totals(cal.rollingDays(7, now: now))
        thisMonth = aggregator.totals(cal.thisCycle(now))
        last30 = aggregator.totals(cal.rollingDays(30, now: now))
        allTime = aggregator.allTime(now: now)
        projected = aggregator.projection(now: now).projected
        projection = ProjectionWording(projected: projected, now: now, cal: cal)
        peakHour = aggregator.peakDownloadHourToday(now: now)
        peakDay = aggregator.peakDownloadDayThisCycle(now: now)
    }

    /// The figure the menu bar shows in `mode`, with the start date its
    /// tooltip names for all time. These are the four rows the menu draws in
    /// full contrast, so the menu and the figure point at each other.
    public func figure(for mode: StatusMode) -> (totals: Totals, since: Date?) {
        switch mode {
        case .today: return (today, nil)
        case .week: return (thisWeek, nil)
        case .month: return (thisMonth, nil)
        case .allTime: return (allTime.totals, allTime.since)
        }
    }

    /// The same figure as `figure(for:)`, worked out on its own. The menu bar
    /// asks for its one figure every five seconds, on the main thread, and
    /// every headline at once costs far more than the one: on 90 days of
    /// minute rows, about a fifth of a second against under a millisecond
    /// for today. The self-test holds the two to the same answer.
    public static func figure(for mode: StatusMode, aggregator: Aggregator,
                              now: Date) -> (totals: Totals, since: Date?) {
        let cal = aggregator.cal
        switch mode {
        case .today: return (aggregator.totals(cal.today(now)), nil)
        case .week: return (aggregator.totals(cal.thisWeek(now)), nil)
        case .month: return (aggregator.totals(cal.thisCycle(now)), nil)
        case .allTime:
            let summary = aggregator.allTime(now: now)
            return (summary.totals, summary.since)
        }
    }
}
