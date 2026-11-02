import Foundation

/// The menu bar item's tooltip: its wording, and when a new one may replace
/// the old.
///
/// The figures in it change every few seconds, but the tooltip must not be
/// replaced while the pointer is elsewhere. macOS treats a new tooltip on a
/// view it believes the pointer is still over as one to show at once, at the
/// pointer, and after a menu bar tooltip has been shown it can go on
/// believing that long after the pointer has left. Replaced every second, the
/// tooltip then popped up across the desktop wherever the pointer happened to
/// be. So a new text waits until the pointer is on the item, and goes in then.
public struct StatusTooltip {

    /// The text the item carries now, nil until the first is set.
    public private(set) var shown: String?
    private var waiting: String?

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

    /// Offers the latest text. Returns the text to set on the item now, or
    /// nil to leave the item alone: when nothing has changed, or when the
    /// pointer is away, in which case the text waits for `pointerArrived()`.
    /// The very first text goes in wherever the pointer is, since there is no
    /// tooltip yet for macOS to show.
    public mutating func offer(_ text: String, pointerOnItem: Bool) -> String? {
        guard text != shown else {
            waiting = nil
            return nil
        }
        guard shown == nil || pointerOnItem else {
            waiting = text
            return nil
        }
        shown = text
        waiting = nil
        return text
    }

    /// The pointer has come onto the item. Returns a text that was waiting,
    /// to set now, before macOS shows the old one.
    public mutating func pointerArrived() -> String? {
        guard let text = waiting else { return nil }
        return offer(text, pointerOnItem: true)
    }
}
