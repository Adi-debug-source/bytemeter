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

    private var rateIn: Double = 0
    private var rateOut: Double = 0
    private var currentTotal = Totals()
    /// When all time began, for the tooltip only. The menu bar text never
    /// carries a date.
    private var currentSince: Date?

    var onOpenDashboard: (() -> Void)?
    var onOpenPreferences: (() -> Void)?
    var onLiveSpeedChanged: (() -> Void)?

    init(settings: Settings, readData: @escaping (@escaping (Aggregator) -> Void) -> Void) {
        self.settings = settings
        self.readData = readData
        super.init()

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
        readData { [weak self] aggregator in
            let now = Date()
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
        readData { aggregator in snapshot = MenuSnapshot(aggregator: aggregator, now: Date()) }
        guard let data = snapshot else { return menu }

        // Standard titles move right by a tick column whenever an item is
        // ticked, and live speed is the only item that can be, so the rows
        // follow it.
        let inset = MenuRows.leadingInset(tickColumn: settings.liveSpeed)
        func header(_ text: String) -> NSMenuItem { MenuRows.header(text, inset: inset) }
        func plain(_ text: String) -> NSMenuItem { MenuRows.text(text, inset: inset) }
        // Strong rows are the four totals the menu bar figure cycles through,
        // so the menu and the figure point at each other; the rest is grey.
        func figure(_ label: String, _ totals: Totals, _ tone: MenuRows.Tone = .quiet) -> NSMenuItem {
            MenuRows.figure(label, down: Units.bytes(totals.bytesIn), up: Units.bytes(totals.bytesOut),
                            tone: tone, inset: inset)
        }

        if settings.liveSpeed {
            menu.addItem(header("Live"))
            menu.addItem(MenuRows.figure("Now", down: Units.rate(rateIn), up: Units.rate(rateOut),
                                         tone: .quiet, inset: inset))
            menu.addItem(.separator())
        }

        menu.addItem(header("Totals"))
        menu.addItem(figure("Today", data.today, .strong))
        menu.addItem(figure("Yesterday", data.yesterday))
        menu.addItem(figure("This week, from Monday", data.thisWeek, .strong))
        menu.addItem(figure("Last 7 days", data.last7))
        menu.addItem(figure(data.cycleLabel, data.thisMonth, .strong))
        menu.addItem(figure("Last 30 days", data.last30))
        if let since = data.allTime.since {
            menu.addItem(figure("All time", data.allTime.totals, .strong))
            menu.addItem(MenuRows.caption("since \(data.cal.dateLabel(since)) · \(data.allTime.daysText) counted",
                                          inset: inset))
        }

        menu.addItem(.separator())
        menu.addItem(header("Averages"))
        menu.addItem(figure("Per hour today", data.perHourToday))
        menu.addItem(figure("Per day this week", data.perDayWeek))
        menu.addItem(figure("Per day this month", data.perDayMonth))
        if data.allTime.since != nil {
            menu.addItem(figure("Per day, all time", data.allTime.perDay))
        }

        menu.addItem(.separator())
        menu.addItem(header("Looking ahead"))
        menu.addItem(plain("At that rate, \(data.cycleEndLabel) ends at \(Units.bytes(data.projected.total))"))
        menu.addItem(plain(data.peakHourText))
        menu.addItem(plain(data.peakDayText))

        // Cap machinery: present and wired, switched off. When a cap is turned
        // on, this is the progress bar that appears, with no rebuild needed.
        if settings.capEnabled, settings.capBytes > 0 {
            menu.addItem(.separator())
            menu.addItem(header("Cap"))
            menu.addItem(plain(capBarText(used: data.thisMonth.total, cap: UInt64(settings.capBytes))))
        }

        menu.addItem(.separator())
        if settings.perAppSampling {
            menu.addItem(header("Top talkers today"))
            if data.topTalkers.isEmpty {
                menu.addItem(plain("Nothing recorded yet"))
            } else {
                for talker in data.topTalkers {
                    menu.addItem(figure(talker.name, talker.totals))
                }
            }
            menu.addItem(MenuRows.text(
                "A guide, not an exact split. See the dashboard.", inset: inset,
                toolTip: "nettop reports totals per process, so a process that quits between samples "
                    + "takes its last few seconds with it. The interface counters are the source of truth, "
                    + "and the two will not reconcile exactly."))
        } else {
            menu.addItem(plain("Per-app sampling is off"))
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
        menu.addItem(MenuRows.text("Right-click or two-finger click the figure to cycle today, week, month and all time.",
                                   inset: inset, wraps: true))
        let quit = NSMenuItem(title: "Quit Bytemeter", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: - Menu helpers

    private func capBarText(used: UInt64, cap: UInt64) -> String {
        let fraction = cap == 0 ? 0 : min(1.0, Double(used) / Double(cap))
        let filled = Int((fraction * 12).rounded())
        let bar = String(repeating: "▰", count: filled) + String(repeating: "▱", count: 12 - filled)
        return "\(bar)  \(Int(fraction * 100))% of \(Units.bytes(cap))"
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

/// Everything the menu needs, gathered in one pass on the database queue.
struct MenuSnapshot {
    let today: Totals
    let yesterday: Totals
    let thisWeek: Totals
    let last7: Totals
    let thisMonth: Totals
    let last30: Totals
    let perHourToday: Totals
    let perDayWeek: Totals
    let perDayMonth: Totals
    let projected: Totals
    let allTime: AllTimeSummary
    let cal: BytemeterCalendar
    let cycleLabel: String
    let cycleEndLabel: String
    let peakHourText: String
    let peakDayText: String
    let topTalkers: [TopTalker]

    init(aggregator: Aggregator, now: Date) {
        let cal = aggregator.cal
        today = aggregator.totals(cal.today(now))
        yesterday = aggregator.totals(cal.yesterday(now))
        thisWeek = aggregator.totals(cal.thisWeek(now))
        last7 = aggregator.totals(cal.rollingDays(7, now: now))
        thisMonth = aggregator.totals(cal.thisCycle(now))
        last30 = aggregator.totals(cal.rollingDays(30, now: now))
        perHourToday = aggregator.averagePerHourToday(now: now)
        perDayWeek = aggregator.averagePerDay(cal.thisWeek(now), now: now)
        perDayMonth = aggregator.averagePerDay(cal.thisCycle(now), now: now)

        let forecast = aggregator.projection(now: now)
        projected = forecast.projected
        allTime = aggregator.allTime(now: now)
        self.cal = cal
        cycleLabel = cal.cycleLabel(now)
        cycleEndLabel = cal.cycleStartDay == 1 ? cal.monthLabel(now) : "the cycle"

        if let peak = aggregator.peakHourToday(now: now) {
            peakHourText = String(format: "Peak hour today: %02d:00, %@", peak.hour, Units.bytes(peak.totals.total))
        } else {
            peakHourText = "Peak hour today: nothing yet"
        }
        if let peak = aggregator.peakDayThisCycle(now: now) {
            peakDayText = "Peak day this month: \(peak.label), \(Units.bytes(peak.totals.total))"
        } else {
            peakDayText = "Peak day this month: nothing yet"
        }
        topTalkers = aggregator.topTalkers(cal.today(now), limit: 5)
    }
}
