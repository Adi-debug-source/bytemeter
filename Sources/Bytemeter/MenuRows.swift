import AppKit

/// The rows in the status item's menu.
///
/// The rows that only inform are drawn by views: AppKit draws a disabled menu
/// item grey whatever colour its attributed title asks for, and these rows
/// must stay disabled, or they would highlight on hover and look clickable. A
/// view is drawn exactly as it is.
///
/// The four period rows are standard items, because they are chosen, and
/// AppKit gives a view item no key events, so Return cannot choose one
/// (tested on macOS 27): as standard items Return, the tick, the highlight and
/// VoiceOver are AppKit's own. Their figure sits at a right tab stop, and the views draw
/// to the same edge, so every figure lines up.
///
/// Deliberately free of anything but AppKit, so the rows can be rendered on
/// their own, in light and dark, to check them without opening the menu.
enum MenuRows {

    /// Where a standard item's title starts. Measured on macOS 27: AppKit pads
    /// a titled item by 34 points in all, and while any item shows a tick it
    /// adds a 14 point column on the left. The period rows always carry a
    /// tick, so the column is always there.
    static let inset: CGFloat = 17 + 14
    /// Where a submenu's rows start: it has no ticks, so no tick column.
    static let plainInset: CGFloat = 17
    /// The right edge of the figures, measured from the text start. AppKit
    /// keeps its shortcut column, about 47 points, to the right of a standard
    /// item's title, so this makes the menu 316 points wide.
    static let figureColumn: CGFloat = 235
    /// How wide a sentence may run before it wraps: to the shortcuts' right
    /// edge, past the figures, since a sentence has no figure to line up.
    static let textColumn: CGFloat = 268
    static let trailingInset: CGFloat = 17
    /// The height AppKit gives a standard item here, so the rows keep the
    /// same rhythm as the commands below them.
    static let rowHeight: CGFloat = 24

    /// One size for every row, AppKit's own menu size, so the rows read at
    /// the same size as the commands; 11 points for headers and captions.
    static let textFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let figureFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    static let captionFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    static let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    static let headerFigureFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    /// The menu bar figure, a point smaller than the rows, as it has always been.
    static let statusItemFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)

    /// The dashboard's accent, for the bars: the one colour in the menu.
    static let accent = NSColor(srgbRed: 0x35 / 255.0, green: 0xa9 / 255.0, blue: 0x9f / 255.0, alpha: 1)

    static func width(inset: CGFloat) -> CGFloat { inset + textColumn + trailingInset }

    // MARK: - Items

    static func header(_ text: String, trailing: String?, inset: CGFloat = inset) -> NSMenuItem {
        let view = MenuRowView(content: .header(text, trailing: trailing), inset: inset, height: rowHeight)
        view.setAccessibilityLabel(trailing.map { "\(text), now \($0)" } ?? text)
        return item(view)
    }

    /// One of the four totals the menu bar cycles through: full contrast,
    /// ticked when it is the one showing, and chosen with a click, Return or
    /// VoiceOver, which send the item's action.
    static func period(_ label: String, down: String, chosen: Bool, toolTip: String?,
                       action: Selector, target: AnyObject, representedObject: Any) -> NSMenuItem {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: figureColumn)]
        // No colour, so AppKit draws it in its own, white while highlighted.
        let title = NSMutableAttributedString(string: label + "\t", attributes: [.font: textFont, .paragraphStyle: style])
        title.append(NSAttributedString(string: "↓ " + down, attributes: [.font: figureFont, .paragraphStyle: style]))
        let row = NSMenuItem(title: label, action: action, keyEquivalent: "")
        row.attributedTitle = title
        row.target = target
        row.representedObject = representedObject
        row.state = chosen ? .on : .off
        row.toolTip = toolTip
        return row
    }

    /// A sentence, grey. One wider than the figure column wraps rather than
    /// widening the menu. With `bar`, a thin bar under it, filled that far.
    static func text(_ text: String, bar: Double? = nil, toolTip: String? = nil) -> NSMenuItem {
        let wraps = (text as NSString).size(withAttributes: [.font: textFont]).width > textColumn
        var height = wraps ? wrappedHeight(text, font: textFont) : rowHeight
        if bar != nil { height += barExtra }
        let view = MenuRowView(content: .text(text, wraps: wraps, bar: bar), inset: inset, height: height)
        view.setAccessibilityLabel(text)
        view.toolTip = toolTip
        let row = item(view)
        row.toolTip = toolTip
        return row
    }

    /// One app in the Top Apps Today submenu: its name, a bar for its share
    /// of the first app's download, and its download.
    static func app(_ name: String, down: String, share: Double) -> NSMenuItem {
        let view = MenuRowView(content: .app(name: name, figure: "↓ " + down, share: share), inset: plainInset,
                               height: rowHeight,
                               width: plainInset + appNameColumn + 10 + appBarWidth + appFigureWidth + trailingInset)
        view.setAccessibilityLabel("\(name): \(down) downloaded today")
        return item(view)
    }

    /// A small grey line, such as the submenu's caveat at its foot.
    static func caption(_ text: String, inset: CGFloat, toolTip: String? = nil) -> NSMenuItem {
        let view = MenuRowView(content: .caption(text), inset: inset, height: 20)
        view.setAccessibilityLabel(text)
        view.toolTip = toolTip
        let row = item(view)
        row.toolTip = toolTip
        return row
    }

    /// The cap's bar: this thick, in this much extra height under its line.
    static let barHeight: CGFloat = 3
    static let barExtra: CGFloat = 6
    /// Room for the longest plain name, "Background downloads".
    static let appNameColumn: CGFloat = 150
    /// The app rows' bars: this wide, ending this far left of the figure's edge.
    static let appBarWidth: CGFloat = 66
    static let appFigureWidth: CGFloat = 70

    private static func item(_ view: MenuRowView) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = view
        return item
    }

    private static func wrappedHeight(_ text: String, font: NSFont) -> CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: textColumn, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        return max(rowHeight, ceil(bounds.height) + 8)
    }
}

final class MenuRowView: NSView {

    enum Content {
        case header(String, trailing: String?)
        case text(String, wraps: Bool, bar: Double?)
        case app(name: String, figure: String, share: Double)
        case caption(String)
    }

    private let content: Content
    private let inset: CGFloat

    init(content: Content, inset: CGFloat, height: CGFloat, width: CGFloat? = nil) {
        self.content = content
        self.inset = inset
        super.init(frame: NSRect(x: 0, y: 0, width: width ?? MenuRows.width(inset: inset), height: height))
        // The menu may be wider than this row, for a long command title; the
        // row stretches, and the figures keep to its right edge.
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// The figures' right edge: the period rows' tab stop in the main menu,
    /// and the row's own edge in the submenu, which has only views.
    private var figureRight: CGFloat {
        if case .app = content { return bounds.width - MenuRows.trailingInset }
        return inset + MenuRows.figureColumn
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender) }

    // MARK: Drawing

    /// Colours are the dynamic system ones, resolved at draw time against the
    /// menu's own appearance, so light and dark menus both come out right.
    override func draw(_ dirtyRect: NSRect) {
        switch content {
        case let .header(text, trailing):
            drawLine(text, font: MenuRows.headerFont, colour: .secondaryLabelColor,
                     width: figureRight - inset - (trailing == nil ? 0 : 90))
            if let trailing {
                drawRight(trailing, font: MenuRows.headerFigureFont, colour: .secondaryLabelColor, right: figureRight)
            }

        case let .text(text, wraps, bar):
            let attributes: [NSAttributedString.Key: Any] = [.font: MenuRows.textFont,
                                                             .foregroundColor: NSColor.secondaryLabelColor]
            // With a bar, the line sits a little higher and the bar under it.
            let barSpace = bar == nil ? 0 : MenuRows.barExtra + 2
            if wraps {
                (text as NSString).draw(with: NSRect(x: inset, y: 4, width: MenuRows.textColumn,
                                                     height: bounds.height - 8 - barSpace),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
            } else {
                drawLine(text, font: MenuRows.textFont, colour: .secondaryLabelColor, width: MenuRows.textColumn,
                         in: bounds.height - barSpace)
            }
            if let bar {
                drawBar(NSRect(x: inset, y: bounds.height - 4 - MenuRows.barHeight, width: figureRight - inset,
                               height: MenuRows.barHeight), fill: bar)
            }

        case let .app(name, figure, share):
            drawRight(figure, font: MenuRows.figureFont, colour: .labelColor, right: figureRight)
            let barRight = figureRight - MenuRows.appFigureWidth
            let barLeft = barRight - MenuRows.appBarWidth
            drawBar(NSRect(x: barLeft, y: (bounds.height - 6) / 2, width: MenuRows.appBarWidth, height: 6), fill: share)
            drawLine(name, font: MenuRows.textFont, colour: .labelColor, width: barLeft - 10 - inset)

        case let .caption(text):
            drawLine(text, font: MenuRows.captionFont, colour: .secondaryLabelColor, width: figureRight - inset)
        }
    }

    /// One line from the left edge, vertically centred in `height` (the
    /// row's by default), cut short with an ellipsis rather than overflowing.
    private func drawLine(_ text: String, font: NSFont, colour: NSColor, width: CGFloat, in height: CGFloat? = nil) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let lineHeight = Self.lineHeight(font)
        let y = ((height ?? bounds.height) - lineHeight) / 2
        (text as NSString).draw(with: NSRect(x: inset, y: y, width: max(0, width), height: lineHeight),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: font, .foregroundColor: colour, .paragraphStyle: style])
    }

    /// Right-aligned at `right`, vertically centred. Returns its width.
    @discardableResult
    private func drawRight(_ text: String, font: NSFont, colour: NSColor, right: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
        let width = (text as NSString).size(withAttributes: attributes).width
        (text as NSString).draw(at: NSPoint(x: right - width, y: (bounds.height - Self.lineHeight(font)) / 2),
                                withAttributes: attributes)
        return width
    }

    /// A rounded track in the faintest grey, filled in the accent from the
    /// left by `fill`, from 0 to 1. Anything above 0 shows at least a sliver.
    private func drawBar(_ rect: NSRect, fill: Double) {
        let radius = rect.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        guard fill > 0 else { return }
        var filled = rect
        filled.size.width = max(rect.height, rect.width * CGFloat(min(1, fill)))
        MenuRows.accent.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}
