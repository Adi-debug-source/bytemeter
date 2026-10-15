import Foundation

// MARK: - Recent events, in plain words

/// How the dashboard words each event in Recent events: a short label for
/// the badge, and a sentence beside it.
///
/// Display only. The stored kind and text are never changed, because the
/// version 2 migration reads the text of past gap events back to find the
/// rows they spread. A gap's text is reworded only when it reads back exactly
/// as `Ledger.spreadDetail` writes it, through the same reader the migration
/// uses; any other text is shown as it was stored, and a kind this build does
/// not know is shown under its own name in words, `some_new_kind` as
/// "Some new kind".
public enum EventWording {

    public static func describe(kind: String, detail: String) -> (label: String, text: String) {
        (label(kind: kind, detail: detail), text(kind: kind, detail: detail))
    }

    private static func label(kind: String, detail: String) -> String {
        switch kind {
        case "baseline": return "New interface"
        case "seed": return "Counting began"
        case "counter_reset": return resetLabel(detail)
        case "counter_wrap": return "Counter wrapped"
        case "counter_source": return "Counter changed"
        case "clock_backwards": return "Clock went back"
        case "clock_caught_up": return "Clock caught up"
        case "gap_sleep": return "Asleep"
        case "gap_relaunch": return "Not running"
        case "gap_normal": return "Gap"
        case "gap_too_long": return "Long gap"
        case "prune": return "Tidy up"
        case "estimated_backfill": return "Upgrade"
        default: return inWords(kind)
        }
    }

    /// A reset is labelled by what the ledger could tell. Both ways it books
    /// a restart say "The Mac restarted", and a reset without one says the
    /// interface itself was reset. When the boot time could not be read to
    /// tell which, or the text is in words this build does not know, the
    /// label claims neither.
    private static func resetLabel(_ detail: String) -> String {
        if detail.contains("The Mac restarted") { return "Restart" }
        if detail.contains("the interface itself was reset") { return "Interface reset" }
        return "Counter reset"
    }

    /// An unknown kind in words: underscores as spaces, the first letter a capital.
    private static func inWords(_ kind: String) -> String {
        let spaced = kind.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// A spread gap as a sentence, for example "en0: 7 h 16 min asleep.
    /// 478 MB down and 68.3 MB up, spread evenly across the gap.", or the
    /// stored text for anything else.
    private static func text(kind: String, detail: String) -> String {
        guard kind.hasPrefix("gap_"), let reason = GapReason(rawValue: String(kind.dropFirst(4))),
              let gap = Ledger.readSpreadDetail(detail)
        else { return detail }
        let circumstance: String
        switch reason {
        case .sleep: circumstance = "asleep"
        case .relaunch: circumstance = "while Bytemeter was not running"
        case .normal: circumstance = "between two readings"
        }
        return "\(gap.iface): \(duration(seconds: gap.elapsed)) \(circumstance). "
            + "\(Units.bytes(gap.deltaIn)) down and \(Units.bytes(gap.deltaOut)) up, spread evenly across the gap."
    }

    /// "45 min", "7 h 16 min", "3 h" or "2 days 5 h": to the nearest minute
    /// under a day, and to the nearest hour from a day up, where minutes
    /// would be detail nobody needs. Each is rounded from the seconds, so
    /// 24 h 29 min 59 s is 1 day, not 1 day 1 h by way of 24 h 30 min.
    /// Never "0 min", and no input can trap.
    static func duration(seconds: Int64) -> String {
        func nearest(_ value: Int64, _ unit: Int64) -> Int64 { value / unit + (value % unit >= unit / 2 ? 1 : 0) }
        let elapsed = max(0, seconds)
        let minutes = max(1, nearest(elapsed, 60))
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 24 * 60 {
            let hours = minutes / 60, rest = minutes % 60
            return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
        }
        let hours = nearest(elapsed, 3_600)
        let days = hours / 24, rest = hours % 24
        let dayText = days == 1 ? "1 day" : "\(days) days"
        return rest == 0 ? dayText : "\(dayText) \(rest) h"
    }
}
