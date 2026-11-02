import Foundation

/// The menu bar item's tooltip: its wording, and when the item carries one.
///
/// The item carries a tooltip only while the pointer is on it. macOS shows a
/// view's tooltip at the pointer whenever it believes the pointer has come
/// onto the view, and for a menu bar item it can believe that when the
/// pointer is nowhere near. 1.2.1 set a new tooltip every second and it popped
/// up across the desktop; 1.2.2 held new ones back while the pointer was away,
/// and it still popped up, unbidden and unchanged, most likely when the
/// item's figure changed width. So with the pointer away the item has no
/// tooltip at all, and there is nothing for macOS to show.
public struct StatusTooltip {

    /// What to do to the item's tooltip.
    public enum Change: Equatable {
        case show(String)
        case clear
    }

    /// The text the item carries now, nil while the pointer is away.
    public private(set) var shown: String?
    private var latest: String?

    public init() {}

    /// The full tooltip. It has room for the upload figure and the start
    /// date that the menu bar text deliberately leaves out.
    public static func text(mode: StatusMode, totals: Totals, since: Date?,
                            calendar: BytemeterCalendar = BytemeterCalendar()) -> String {
        // The month figure is the billing cycle's when one is set, so it is
        // called a cycle, as the menu calls it.
        var label = mode == .month && calendar.cycleStartDay != 1 ? "This cycle" : mode.label
        if mode == .allTime, let since {
            label += ", since " + calendar.dateLabel(since)
        }
        return "Bytemeter: \(label). "
            + "Down \(Units.bytes(totals.bytesIn)), up \(Units.bytes(totals.bytesOut)). "
            + "Click for the menu. Right-click, two-finger click or Control-click to cycle "
            + "today, week, month and all time."
    }

    /// Offers the latest text, each time the figures are drawn. Returns the
    /// change to make to the item now, or nil to leave it alone. With the
    /// pointer away that is a clear, which also takes off a tooltip left
    /// behind by a missed exit.
    public mutating func offer(_ text: String, pointerOnItem: Bool) -> Change? {
        latest = text
        return pointerOnItem ? show(text) : pointerLeft()
    }

    /// The pointer has come onto the item: the latest text goes in.
    public mutating func pointerArrived() -> Change? {
        latest.flatMap { show($0) }
    }

    /// The pointer has left the item: the tooltip comes off.
    public mutating func pointerLeft() -> Change? {
        guard shown != nil else { return nil }
        shown = nil
        return .clear
    }

    private mutating func show(_ text: String) -> Change? {
        guard text != shown else { return nil }
        shown = text
        return .show(text)
    }
}
