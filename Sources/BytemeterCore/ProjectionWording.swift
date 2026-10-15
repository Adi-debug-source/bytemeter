import Foundation

// MARK: - The projection, worded once

/// What the month is on track for, in the same words on the menu and on the
/// dashboard.
///
/// Like the cap, it adds download and upload together, because a provider's
/// allowance counts both directions. Every other headline figure is download
/// alone, so it says so wherever it appears. And it names the end of the
/// month in words: "by 1 Oct", seen on 29 September, read as if the month ran
/// into October.
public struct ProjectionWording: Equatable {
    /// "100.8 GB", download and upload together, or "Too early" when there
    /// is no figure yet.
    public let figure: String
    /// "by the end of September", or "by the end of the cycle, 14 Oct" when a
    /// billing cycle starts on another day.
    public let deadline: String
    /// The menu's line. The dashboard shows the same parts as a tile.
    public let headline: String
    /// The tile's heading: "On track for", or "Projection" when it is too
    /// early, since "On track for" over "Too early" is not a sentence.
    public let title: String
    /// Under the tile's figure: the deadline, or "to project October" when
    /// it is too early, so the tile reads as the menu's line does.
    public let qualifier: String
    /// True when there is no figure to give: under a day has been counted,
    /// or nothing at all. The caption beside it then says why.
    public let isTooEarly: Bool

    /// Said beside the figure wherever it appears.
    public static let basis = "down and up combined, as a provider counts it"
    /// Said in place of `basis` when it is too early to project.
    public static let tooEarlyBasis = "a day of counting is needed first"

    /// `projected` is nil when it is too early to project.
    public init(projected: Totals?, now: Date, cal: BytemeterCalendar) {
        // The cycle ends at the first moment of the next one, so its last
        // day is the day before that.
        let lastDay = cal.addDays(-1, to: cal.endOfCycle(now))
        let period: String
        if cal.cycleStartDay == 1 {
            period = cal.monthName(lastDay)
            deadline = "by the end of " + period
        } else {
            period = "the cycle ending " + cal.dayLabel(lastDay)
            deadline = "by the end of the cycle, " + cal.dayLabel(lastDay)
        }
        if let projected {
            figure = Units.bytes(projected.total)
            headline = "On track for \(figure) \(deadline)"
            title = "On track for"
            qualifier = deadline
            isTooEarly = false
        } else {
            figure = "Too early"
            headline = "Too early to project " + period
            title = "Projection"
            qualifier = "to project " + period
            isTooEarly = true
        }
    }
}
