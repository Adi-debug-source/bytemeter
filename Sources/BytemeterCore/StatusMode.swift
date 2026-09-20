import Foundation

/// Which total the menu bar shows. Clicking the status item cycles through
/// these in order, and the choice is remembered across restarts.
///
/// It lives in the shared engine rather than the macOS app because an iOS
/// sibling wants exactly the same three, with the same order and labels.
public enum StatusMode: String, CaseIterable {
    case today
    case week
    case month

    public var label: String {
        switch self {
        case .today: return "Today"
        case .week: return "This week"
        case .month: return "This month"
        }
    }

    public var next: StatusMode {
        let all = StatusMode.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}
