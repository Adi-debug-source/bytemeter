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
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
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
            let totals: Totals
            var since: Date?
            switch mode {
            case .today: totals = aggregator.totals(aggregator.cal.today(now))
            case .week: totals = aggregator.totals(aggregator.cal.thisWeek(now))
            case .month: totals = aggregator.totals(aggregator.cal.thisCycle(now))
            case .allTime:
                let summary = aggregator.allTime(now: now)
                totals = summary.totals
                since = summary.since
            }
            DispatchQueue.main.async {
                self?.currentTotal = totals
                self?.currentSince = since
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
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])
        // The tooltip has room for the start date that the menu bar text
        // deliberately leaves out.
        var mode = settings.statusMode.label
        if settings.statusMode == .allTime, let since = currentSince {
            mode += ", since " + BytemeterCalendar().dateLabel(since)
        }
        button.toolTip = "Bytemeter: \(mode). "
            + "Down \(Units.bytes(currentTotal.bytesIn)), up \(Units.bytes(currentTotal.bytesOut)). "
            + "Click for the menu. Right-click, two-finger click or Control-click to cycle "
            + "today, week, month and all time."
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
            return MenuRows.text(text, inset: inset, toolTip: toolTip)
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
