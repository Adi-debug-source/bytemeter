import Foundation

// MARK: - The monthly cap, worded once

/// How the month or billing cycle so far stands against the cap, in the same
/// words in the menu and on the dashboard.
///
/// `used` is download and upload together, because a provider's allowance
/// counts both directions. The percentage is the real one, past 100 when the
/// cap is passed: a figure that stopped at 100% read the same at 61 GB and at
/// 97 GB against a 60 GB cap. Only the bar stops at full, because it has no
/// room to go further.
public struct CapProgress: Equatable {
    /// Used over cap, not clamped. 0 for a cap of 0, which is never shown.
    public let fraction: Double
    /// Whole per cent, rounded down and not clamped, so 99.99% reads 99%
    /// until the cap is really reached.
    public let percent: Int
    /// How full the menu's bar is drawn, from 0 to 1: the percentage, so it
    /// rounds down the same way and is full only from the cap on. Rounded to
    /// the nearest, it was full at 95.9% beside "2.40 GB left".
    public let barFill: Double
    /// The menu's line: "52.0 of 60.0 GB, 2 days left", "60.0 of 60.0 GB,
    /// cap reached" or "90.0 of 60.0 GB, 30.0 GB over the cap".
    public let menuText: String
    /// "8.00 GB left, 16 days to go", "Cap reached" or "37.1 GB over the cap".
    public let remainingText: String

    /// Said beside the cap wherever it appears.
    public static let basis = "Download and upload together, as a provider counts them"

    public init(used: UInt64, cap: UInt64, now: Date, cal: BytemeterCalendar) {
        fraction = cap == 0 ? 0 : Double(used) / Double(cap)
        percent = Self.wholePercent(used, of: cap)
        barFill = Double(min(100, percent)) / 100

        let tail: String
        if used < cap {
            // From today to the cycle's last day, both counted: the cycle
            // ends at the first moment of the next one, so its last day is
            // the day before that, and on that day there is 1 day to go.
            let lastDay = cal.addDays(-1, to: cal.endOfCycle(now))
            let days = cal.daysBetween(now, lastDay) + 1
            let dayCount = "\(days) \(days == 1 ? "day" : "days")"
            remainingText = "\(Units.bytes(cap - used)) left, \(dayCount) to go"
            tail = dayCount + " left"
        } else if used == cap {
            remainingText = "Cap reached"
            tail = "cap reached"
        } else {
            remainingText = "\(Units.bytes(used - cap)) over the cap"
            tail = remainingText
        }
        menuText = "\(Self.usedOfCap(used, cap)), \(tail)"
    }

    /// "52.0 of 60.0 GB": the unit once when both figures share it, and
    /// "820 MB of 60.0 GB" when they do not.
    private static func usedOfCap(_ used: UInt64, _ cap: UInt64) -> String {
        let usedText = Units.bytes(used), capText = Units.bytes(cap)
        let unit = { (text: String) in text.split(separator: " ").last }
        guard let usedUnit = unit(usedText), usedUnit == unit(capText) else { return "\(usedText) of \(capText)" }
        return "\(usedText.dropLast(usedUnit.count + 1)) of \(capText)"
    }

    /// `used` as a whole percentage of `cap`, rounded down, in integers.
    /// Floating point would put 29 bytes of 100 at 28.999...%, which rounds
    /// down to 28. Whole caps first, then the remainder, which is smaller
    /// than the cap, so neither step can overflow.
    private static func wholePercent(_ used: UInt64, of cap: UInt64) -> Int {
        guard cap > 0 else { return 0 }
        let (whole, overflow) = (used / cap).multipliedReportingOverflow(by: 100)
        let rest = cap.dividingFullWidth((used % cap).multipliedFullWidth(by: 100)).quotient
        guard !overflow, whole <= UInt64(Int.max) - rest else { return Int.max }
        return Int(whole + rest)
    }
}
