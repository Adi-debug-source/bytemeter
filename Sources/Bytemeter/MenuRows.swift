import AppKit

/// The information rows in the status item's menu, each drawn by a view.
///
/// Why views: AppKit draws a disabled menu item grey whatever colour its
/// attributed title asks for, and these rows must stay disabled, or they would
/// highlight on hover and look clickable. A view is drawn exactly as it is.
/// Every information row is a view, not only the white ones, so headings,
/// figures and notes share one left edge and one pair of number columns. Only
/// the actions at the bottom are standard items.
///
/// Deliberately free of anything but AppKit, so the rows can be rendered on
/// their own, in light and dark, to check them without opening the menu.
enum MenuRows {

    enum Tone {
        /// Full contrast: the totals the menu bar figure cycles through.
        case strong
        /// Grey: everything else, which is supporting detail.
        case quiet
    }

    /// Where a standard item's title starts. Measured on macOS 27: AppKit pads
    /// a titled item by 34 points in all, and while any item shows a tick it
    /// adds a 14 point column on the left. The 34 is assumed to split evenly,
    /// which the menu sizes alone cannot confirm; only the boundary with the
    /// action items below depends on it.
    static func leadingInset(tickColumn: Bool) -> CGFloat { 17 + (tickColumn ? 14 : 0) }

    /// Right edges of the down and up figures, measured from the text start.
    static let downColumn: CGFloat = 240
    static let upColumn: CGFloat = 330
    static let trailingInset: CGFloat = 17
    /// The height AppKit gives a standard item here, so the block keeps the
    /// same rhythm as the actions below it.
    static let rowHeight: CGFloat = 24

    static let figureFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
    static let textFont = NSFont.systemFont(ofSize: NSFont.systemFontSize - 1)
    static let captionFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    static let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)

    static func width(inset: CGFloat) -> CGFloat { inset + upColumn + trailingInset }

    // MARK: - Items

    /// A label with down and up figures, the whole row in one tone. Down still
    /// leads by position and by its arrow; colour is kept for the one thing
    /// it says here, which totals the menu bar figure cycles through.
    static func figure(_ label: String, down: String, up: String, tone: Tone, inset: CGFloat) -> NSMenuItem {
        let view = MenuRowView(content: .figure(label: label, down: "↓ " + down, up: "↑ " + up, tone: tone),
                               inset: inset, height: rowHeight)
        view.setAccessibilityLabel("\(label): down \(down), up \(up)")
        return item(view)
    }

    static func header(_ text: String, inset: CGFloat) -> NSMenuItem {
        let view = MenuRowView(content: .text(text.uppercased(), font: headerFont, tone: .quiet, wraps: false),
                               inset: inset, height: rowHeight)
        view.setAccessibilityLabel(text)
        return item(view)
    }

    /// A sentence. Wrapping ones grow to fit within the figure columns rather
    /// than widening the whole menu.
    static func text(_ text: String, inset: CGFloat, tone: Tone = .quiet, wraps: Bool = false,
                     toolTip: String? = nil) -> NSMenuItem {
        let height = wraps ? wrappedHeight(text, font: textFont) : rowHeight
        let view = MenuRowView(content: .text(text, font: textFont, tone: tone, wraps: wraps),
                               inset: inset, height: height)
        view.setAccessibilityLabel(text)
        view.toolTip = toolTip
        let row = item(view)
        row.toolTip = toolTip
        return row
    }

    /// A small grey line under the row above it, such as where all time starts.
    static func caption(_ text: String, inset: CGFloat) -> NSMenuItem {
        let view = MenuRowView(content: .text(text, font: captionFont, tone: .quiet, wraps: false),
                               inset: inset, height: 16, verticalOffset: -4)
        view.setAccessibilityLabel(text)
        return item(view)
    }

    private static func item(_ view: MenuRowView) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = view
        return item
    }

    private static func wrappedHeight(_ text: String, font: NSFont) -> CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: upColumn, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        return max(rowHeight, ceil(bounds.height) + 8)
    }
}

final class MenuRowView: NSView {

    enum Content {
        case figure(label: String, down: String, up: String, tone: MenuRows.Tone)
        case text(String, font: NSFont, tone: MenuRows.Tone, wraps: Bool)
    }

    private let content: Content
    private let inset: CGFloat
    private let verticalOffset: CGFloat

    init(content: Content, inset: CGFloat, height: CGFloat, verticalOffset: CGFloat = 0) {
        self.content = content
        self.inset = inset
        self.verticalOffset = verticalOffset
        super.init(frame: NSRect(x: 0, y: 0, width: MenuRows.width(inset: inset), height: height))
        // The menu may be wider than this row, for a long action title; the
        // row stretches, and everything is drawn from the left, so nothing moves.
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender) }

    /// Colours are the dynamic system ones, resolved at draw time against the
    /// menu's own appearance, so light and dark menus both come out right.
    private static func colour(_ tone: MenuRows.Tone) -> NSColor {
        tone == .strong ? .labelColor : .secondaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        switch content {
        case let .figure(label, down, up, tone):
            let font = MenuRows.figureFont
            let y = (bounds.height - Self.lineHeight(font)) / 2 + verticalOffset
            let main: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Self.colour(tone)]

            let downWidth = (down as NSString).size(withAttributes: main).width
            let upWidth = (up as NSString).size(withAttributes: main).width
            let downRight = inset + MenuRows.downColumn
            let upRight = inset + MenuRows.upColumn
            (down as NSString).draw(at: NSPoint(x: downRight - downWidth, y: y), withAttributes: main)
            (up as NSString).draw(at: NSPoint(x: upRight - upWidth, y: y), withAttributes: main)

            // A long process name is cut short rather than pushing the figures
            // out of their columns.
            let labelWidth = max(0, downRight - downWidth - 12 - inset)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            var labelAttributes = main
            labelAttributes[.paragraphStyle] = style
            (label as NSString).draw(with: NSRect(x: inset, y: y, width: labelWidth, height: Self.lineHeight(font)),
                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                     attributes: labelAttributes)

        case let .text(text, font, tone, wraps):
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Self.colour(tone)]
            let width = MenuRows.upColumn
            if wraps {
                (text as NSString).draw(with: NSRect(x: inset, y: 4 + verticalOffset, width: width, height: bounds.height - 8),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                                        attributes: attributes)
            } else {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byTruncatingTail
                var single = attributes
                single[.paragraphStyle] = style
                let lineHeight = Self.lineHeight(font)
                let y = (bounds.height - lineHeight) / 2 + verticalOffset
                (text as NSString).draw(with: NSRect(x: inset, y: y, width: width, height: lineHeight),
                                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: single)
            }
        }
    }
}
