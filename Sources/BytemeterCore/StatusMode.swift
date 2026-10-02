import Foundation

/// Which total the menu bar shows. Clicking the status item cycles through
/// these in order, and the choice is remembered across restarts.
///
/// It lives in the shared engine rather than the macOS app because an iOS
/// sibling wants the same four, in the same order and with the same labels.
public enum StatusMode: String, CaseIterable {
    case today
    case week
    case month
    case allTime = "all_time"

    /// Short on purpose: this is the menu bar's text. The start date and the
    /// day count for all time belong in the menu and on the dashboard.
    public var label: String {
        switch self {
        case .today: return "Today"
        case .week: return "This week"
        case .month: return "This month"
        case .allTime: return "All time"
        }
    }

    public var next: StatusMode {
        let all = StatusMode.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    /// The mode saved in settings. Anything missing or unrecognised, such as
    /// a value written by a later version, comes back as today rather than
    /// failing.
    public init(saved raw: String?) {
        self = raw.flatMap(StatusMode.init(rawValue:)) ?? .today
    }
}
