import AppKit
import BytemeterCore

/// The menu bar item and its dropdown.
///
/// The status item shows one total. Clicking opens the menu, the way every
/// other menu bar item behaves; right-click, a two-finger click or
/// Control-click cycles the total through today, this week, this month and
/// all time. Live speed is a separate toggle that sits alongside the total
/// rather than replacing it.
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings: Settings
    private let readData: (@escaping (Aggregator) -> Void) -> Void
    /// The moment the figures describe. The clock, except in demo mode, where
    /// it can be a fixed moment so a screenshot can be taken at any hour.
    private let clock: () -> Date

    private var rateIn: Double = 0
    private var rateOut: Double = 0
    private var currentTotal = Totals()
    /// When all time began, for the tooltip only. The menu bar text never
    /// carries a date.
    private var currentSince: Date?
    /// Gives the item a tooltip only while the pointer is on it; see
    /// `StatusTooltip` for why.
    private var tooltip = StatusTooltip()

    var onOpenDashboard: (() -> Void)?
    var onOpenPreferences: (() -> Void)?
    var onLiveSpeedChanged: (() -> Void)?

    /// `autosaveName` keeps a demo's item from sharing the real item's name,
    /// under which macOS remembers where the item sits in the menu bar.
    init(settings: Settings,
         clock: @escaping () -> Date = { Date() },
         autosaveName: String? = nil,
         readData: @escaping (@escaping (Aggregator) -> Void) -> Void) {
        self.settings = settings
        self.clock = clock
        self.readData = readData
        super.init()
        if let autosaveName { statusItem.autosaveName = autosaveName }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.font = MenuRows.figureFont
            // Tells the controller when the pointer comes onto the item and
            // leaves it, so the item carries a tooltip only in between.
            // `inVisibleRect` keeps the area the item's size as it changes.
            button.addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil))
        }
        refresh()
    }

    // MARK: - Status item

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
        let isControlClick = event?.modifierFlags.contains(.control) ?? false

        // A two-finger click on a trackpad arrives as a right click.
        if isRight || isControlClick {
            settings.statusMode = settings.statusMode.next
            refresh()
        } else {
            showMenu()
        }
    }

    func showMenu() {
        let menu = buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
        // An open menu can swallow the exit, so the tooltip comes off here
        // rather than at the next draw.
        if !pointerIsOnItem { apply(tooltip.pointerLeft()) }
    }

    func updateRate(inBytes: Double, outBytes: Double) {
        rateIn = inBytes
        rateOut = outBytes
        render()
    }

    /// Pull the current total for whichever mode is showing, then redraw.
    func refresh() {
        let mode = settings.statusMode
        let now = clock()
        readData { [weak self] aggregator in
            // Only the one figure: this runs every five seconds.
            let figure = Headlines.figure(for: mode, aggregator: aggregator, now: now)
            DispatchQueue.main.async {
                self?.currentTotal = figure.totals
                self?.currentSince = figure.since
                self?.render()
            }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        var text = "↓ " + Units.bytes(currentTotal.bytesIn, compact: true)
        if settings.liveSpeed {
            text += " · " + Units.rate(rateIn)
        }
        let tip = StatusTooltip.text(mode: settings.statusMode, totals: currentTotal, since: currentSince,
                                     calendar: BytemeterCalendar(cycleStartDay: settings.cycleStartDay))
        button.setAccessibilityHelp(tip)
        // Before the title, whose change of width is the likely trigger, so a
        // tooltip a missed exit left is off the item by the time it resizes.
        apply(tooltip.offer(tip, pointerOnItem: pointerIsOnItem))
        button.attributedTitle = NSAttributedString(string: text, attributes: [.font: MenuRows.figureFont])
    }

    /// The only place the item's tooltip is set: from what `StatusTooltip`
    /// returns, so the item never carries one while the pointer is away.
    private func apply(_ change: StatusTooltip.Change?) {
        guard let change, let button = statusItem.button else { return }
        switch change {
        case .show(let text): button.toolTip = text
        case .clear: button.toolTip = nil
        }
    }

    /// Whether the pointer is over the item now, read from where it is rather
    /// than from the tracking area, so a missed exit cannot leave it true.
    private var pointerIsOnItem: Bool {
        guard let frame = statusItem.button?.window?.frame else { return false }
        // NSMouseInRect, unlike contains, counts the top edge, where a
        // pointer pushed to the top of the screen sits.
        return NSMouseInRect(NSEvent.mouseLocation, frame, false)
    }

    /// Both handlers carry their Objective-C names, since Swift alone would
    /// export them as `mouseEnteredWith:` and `mouseExitedWith:`, which the
    /// tracking area never sends.
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        apply(tooltip.pointerArrived())
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        apply(tooltip.pointerLeft())
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        var snapshot: MenuSnapshot?
        let now = clock()
        readData { aggregator in snapshot = MenuSnapshot(aggregator: aggregator, now: now) }
        guard let data = snapshot else { return menu }

        // Standard titles move right by a tick column whenever an item is
        // ticked, and live speed is the only item that can be, so the rows
        // follow it.
        let inset = MenuRows.leadingInset(tickColumn: settings.liveSpeed)
        let options = MenuModel.Options(liveSpeed: settings.liveSpeed, rateIn: rateIn, rateOut: rateOut,
                                        capEnabled: settings.capEnabled,
                                        capBytes: UInt64(max(0, settings.capBytes)),
                                        perAppSampling: settings.perAppSampling)
        for line in MenuModel.information(data, options: options) {
            menu.addItem(item(for: line, inset: inset))
        }

        menu.addItem(.separator())
        let live = NSMenuItem(title: "Live speed in the menu bar", action: #selector(toggleLiveSpeed), keyEquivalent: "")
        live.target = self
        live.state = settings.liveSpeed ? .on : .off
        menu.addItem(live)

        let dashboard = NSMenuItem(title: "Open dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        dashboard.target = self
        menu.addItem(dashboard)

        let preferences = NSMenuItem(title: "Preferences", action: #selector(openPreferences), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)

        menu.addItem(.separator())
        menu.addItem(MenuRows.text(MenuModel.hint, inset: inset, wraps: true))
        let quit = NSMenuItem(title: "Quit Bytemeter", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: - Menu helpers

    /// One line of the menu as a row. Strong lines, the four totals the menu
    /// bar cycles through, are full contrast; every other row is grey.
    private func item(for line: MenuLine, inset: CGFloat) -> NSMenuItem {
        switch line {
        case let .header(text):
            return MenuRows.header(text, inset: inset)
        case let .figure(label, down, up, strong):
            return MenuRows.figure(label, down: down, up: up, tone: strong ? .strong : .quiet, inset: inset)
        case let .text(text, toolTip):
            // Most sentences fit on one line. One that does not, such as the
            // line that says recording has stopped, wraps rather than losing
            // its end.
            return MenuRows.text(text, inset: inset, wraps: MenuRows.overflows(text), toolTip: toolTip)
        case let .caption(text):
            return MenuRows.caption(text, inset: inset)
        case .separator:
            return .separator()
        }
    }

    // MARK: - Actions

    @objc private func toggleLiveSpeed() {
        settings.liveSpeed.toggle()
        onLiveSpeedChanged?()
        render()
    }

    @objc private func openDashboard() { onOpenDashboard?() }
    @objc private func openPreferences() { onOpenPreferences?() }
    @objc private func quit() { NSApp.terminate(nil) }
}
