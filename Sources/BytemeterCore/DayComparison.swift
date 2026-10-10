import Foundation

/// Today so far against yesterday, in words, for the dashboard.
///
/// Set against yesterday up to the same time of day, not against all of it:
/// part of a day against a whole one read "Down on yesterday" nearly every
/// morning, however alike the two days were. Download only, like every
/// headline figure, with the same five per cent either way before it calls
/// a change.
public enum DayComparison {

    /// `yesterdaySoFar` is yesterday up to the same time, from
    /// `BytemeterCalendar.yesterdayUntil`; `yesterday` is the whole of it.
    public static func text(today: Totals, yesterdaySoFar: Totals, yesterday: Totals) -> String {
        guard yesterday.bytesIn > 0 else { return "No figure for yesterday to compare against yet." }
        let wholeDay = Units.bytes(yesterday.bytesIn)
        guard yesterdaySoFar.bytesIn > 0 else {
            return "Yesterday had nothing by this time, and came to \(wholeDay) in all."
        }
        let change = Double(today.bytesIn) / Double(yesterdaySoFar.bytesIn)
        let reference = "at this time, when it had reached \(Units.bytes(yesterdaySoFar.bytesIn)). "
            + "Yesterday came to \(wholeDay) in all."
        if change >= 1.05 {
            return "Up on yesterday " + reference
        } else if change <= 0.95 {
            return "Down on yesterday " + reference
        }
        return "About the same as yesterday " + reference
    }
}
