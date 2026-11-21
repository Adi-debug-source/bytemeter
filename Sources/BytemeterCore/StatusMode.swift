import Foundation

/// Which total the menu bar shows. A click on the status item opens the menu;
/// a right-click, a two-finger click or a Control-click cycles through these
/// in order, and the choice is remembered across restarts.
///
/// It lives in the shared engine rather than the macOS app because an iOS
/// sibling wants the same four, in the same order and with the same labels.
/// They are Tokenmeter's four, so the two apps' menu bars read alike: the
/// calendar week and month are on the dashboard.
public enum StatusMode: String, CaseIterable {
    case today
    case last7 = "last_7_days"
    case last30 = "last_30_days"
    case allTime = "all_time"

    /// Short on purpose: this is the menu bar's text. The start date and the
    /// day count for all time belong in the menu and on the dashboard.
    public var label: String {
        switch self {
        case .today: return "Today"
        case .last7: return "Last 7 days"
        case .last30: return "Last 30 days"
        case .allTime: return "All time"
        }
    }

    public var next: StatusMode {
        let all = StatusMode.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    /// The mode saved in settings. Up to 1.3.1 the four were today, the
    /// calendar week and month, and all time, so a saved week or month comes
    /// back as the rolling period nearest it. Anything missing or
    /// unrecognised, such as a value written by a later version, comes back
    /// as today rather than failing.
    public init(saved raw: String?) {
        switch raw {
        case "week": self = .last7
        case "month": self = .last30
        default: self = raw.flatMap(StatusMode.init(rawValue:)) ?? .today
        }
    }
}
