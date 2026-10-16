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
    /// Twelve cells, rounded down like the percentage, so the bar is full
    /// only from the cap on: at 95.9% it showed twelve cells beside "2.40 GB
    /// left".
    public let barText: String
    /// The menu's line: the bar, then "161% of 60.0 GB".
    public let menuText: String
    /// "8.00 GB left, 16 days to go", "Cap reached" or "37.1 GB over the cap".
    public let remainingText: String

    public init(used: UInt64, cap: UInt64, now: Date, cal: BytemeterCalendar) {
        fraction = cap == 0 ? 0 : Double(used) / Double(cap)
        percent = Self.wholePercent(used, of: cap)

        let filled = Int((min(1.0, fraction) * 12).rounded(.down))
        barText = String(repeating: "▰", count: filled) + String(repeating: "▱", count: 12 - filled)
        menuText = "\(barText)  \(percent)% of \(Units.bytes(cap))"

        if used < cap {
            // From today to the cycle's last day, both counted: the cycle
            // ends at the first moment of the next one, so its last day is
            // the day before that, and on that day there is 1 day to go.
            let lastDay = cal.addDays(-1, to: cal.endOfCycle(now))
            let days = cal.daysBetween(now, lastDay) + 1
            remainingText = "\(Units.bytes(cap - used)) left, \(days) \(days == 1 ? "day" : "days") to go"
        } else if used == cap {
            remainingText = "Cap reached"
        } else {
            remainingText = "\(Units.bytes(used - cap)) over the cap"
        }
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
