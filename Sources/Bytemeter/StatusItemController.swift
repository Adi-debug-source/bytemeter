import AppKit
import BytemeterCore

/// The menu bar item and its dropdown.
///
/// The status item shows one total, and clicking it cycles today, this week and
/// this month. Live speed is a separate toggle that sits alongside the total
/// rather than replacing it.
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings: Settings
    private let readData: (@escaping (Aggregator) -> Void) -> Void

    private var rateIn: Double = 0
    private var rateOut: Double = 0
    private var currentTotal = Totals()

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

        if isRight || isControlClick {
            showMenu()
        } else {
            settings.statusMode = settings.statusMode.next
            refresh()
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
            let range: MinuteRange
            switch mode {
            case .today: range = aggregator.cal.today(now)
            case .week: range = aggregator.cal.thisWeek(now)
            case .month: range = aggregator.cal.thisCycle(now)
            }
            let totals = aggregator.totals(range)
            DispatchQueue.main.async {
                self?.currentTotal = totals
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
        button.toolTip = "Bytemeter: \(settings.statusMode.label). "
            + "Down \(Units.bytes(currentTotal.bytesIn)), up \(Units.bytes(currentTotal.bytesOut)). "
            + "Click to cycle, right-click for the menu."
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        var snapshot: MenuSnapshot?
        readData { aggregator in snapshot = MenuSnapshot(aggregator: aggregator, now: Date()) }
        guard let data = snapshot else { return menu }

        if settings.liveSpeed {
            menu.addItem(header("Live"))
            menu.addItem(figure("Now", down: Units.rate(rateIn), up: Units.rate(rateOut)))
            menu.addItem(.separator())
        }

        menu.addItem(header("Totals"))
        menu.addItem(figure("Today", totals: data.today))
        menu.addItem(figure("Yesterday", totals: data.yesterday))
        menu.addItem(figure("This week, from Monday", totals: data.thisWeek))
        menu.addItem(figure("Last 7 days", totals: data.last7))
        menu.addItem(figure(data.cycleLabel, totals: data.thisMonth))
        menu.addItem(figure("Last 30 days", totals: data.last30))

        menu.addItem(.separator())
        menu.addItem(header("Averages"))
        menu.addItem(figure("Per hour today", totals: data.perHourToday))
        menu.addItem(figure("Per day this week", totals: data.perDayWeek))
        menu.addItem(figure("Per day this month", totals: data.perDayMonth))

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
                    menu.addItem(figure(talker.name, totals: talker.totals))
                }
            }
            let note = plain("A guide, not an exact split. See the dashboard.")
            note.toolTip = "nettop reports totals per process, so a process that quits between samples "
                + "takes its last few seconds with it. The interface counters are the source of truth, "
                + "and the two will not reconcile exactly."
            menu.addItem(note)
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
        menu.addItem(plain("Click the menu bar figure to cycle today, week and month."))
        let quit = NSMenuItem(title: "Quit Bytemeter", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: - Menu item builders

    private func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    private func plain(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize - 1),
            .foregroundColor: NSColor.labelColor,
        ])
        return item
    }

    private func figure(_ label: String, totals: Totals) -> NSMenuItem {
        figure(label, down: Units.bytes(totals.bytesIn), up: Units.bytes(totals.bytesOut))
    }

    /// Down is the headline, up sits on the same line. Tab stops keep the
    /// columns lined up without forcing a monospaced font on the whole menu.
    private func figure(_ label: String, down: String, up: String) -> NSMenuItem {
        let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let style = NSMutableParagraphStyle()
        style.tabStops = [
            NSTextTab(textAlignment: .right, location: 240),
            NSTextTab(textAlignment: .right, location: 330),
        ]
        let text = NSMutableAttributedString(string: "\(label)\t↓ \(down)\t↑ \(up)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular),
            .paragraphStyle: style,
            .foregroundColor: NSColor.labelColor,
        ])
        let upRange = (text.string as NSString).range(of: "↑ \(up)")
        if upRange.location != NSNotFound {
            text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: upRange)
        }
        item.attributedTitle = text
        return item
    }

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
        cycleLabel = cal.cycleStartDay == 1 ? "This month" : "This cycle"
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
