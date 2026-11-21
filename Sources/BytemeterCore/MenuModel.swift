import Foundation

/// One line of the status item's menu, before anything draws it.
///
/// What the menu says is worked out here, in the shared engine, as plain
/// values: the macOS app draws each line with a view, and the self-test reads
/// exactly what the menu would show without opening a menu. The demo mode and
/// the real app build their menus through this same code, so the demo cannot
/// drift from the real thing.
///
/// Every figure in the menu is download, as the menu bar's is. Upload, the
/// averages, the rolling periods and the peaks are on the dashboard.
public enum MenuLine: Equatable {
    /// A small grey heading. `trailing` sits at its right edge: the live rate,
    /// while live speed is on.
    case header(String, trailing: String?)
    /// Only while something is wrong or counting has only just begun.
    case warning(String, toolTip: String?)
    /// One of the four totals the menu bar cycles through, in full contrast.
    /// Choosing it shows it in the menu bar; `chosen` is the one showing now.
    case period(StatusMode, label: String, down: String, chosen: Bool, toolTip: String?)
    /// The one sentence about where the month is heading. `bar` is how full
    /// the cap is, from 0 to 1, when a cap is set and the line is about it.
    case insight(String, bar: Double?, toolTip: String?)
    case separator
}

/// One app in the Top Apps Today submenu.
public struct MenuApp: Equatable {
    /// Its plain name, from `ProcessNames`.
    public let name: String
    public let down: String
    /// Its download as a share of the first app's, from 0 to 1, for its bar.
    public let share: Double
}

/// Everything the menu needs, gathered in one pass on the database queue.
/// The totals and the projection come from `Headlines`, the same figures the
/// dashboard and the menu bar show.
public struct MenuSnapshot {
    public let today: Totals
    public let thisWeek: Totals
    public let thisMonth: Totals
    /// Worded once, in `Headlines`, for the menu and the dashboard alike.
    public let projection: ProjectionWording
    public let allTime: AllTimeSummary
    public let cal: BytemeterCalendar
    /// The moment described, for the figures that count days from it.
    public let now: Date
    public let topTalkers: [TopTalker]
    /// When writes to the database began failing, or nil while they go
    /// through. Read from the same database, on its queue, with the figures.
    public let notRecordingSince: Date?

    /// `now` is the moment the menu describes: the clock for the real app, or
    /// a fixed moment for a demo or a test.
    public init(aggregator: Aggregator, now: Date) {
        let cal = aggregator.cal
        let headlines = Headlines(aggregator: aggregator, now: now)
        today = headlines.today
        thisWeek = headlines.thisWeek
        thisMonth = headlines.thisMonth
        projection = headlines.projection
        allTime = headlines.allTime
        self.cal = cal
        self.now = now
        topTalkers = aggregator.topTalkers(cal.today(now), limit: MenuModel.topAppsLimit)
        notRecordingSince = aggregator.db.failingSince
    }
}

public enum MenuModel {

    /// The settings that change what the menu shows.
    public struct Options {
        public var statusMode: StatusMode
        public var liveSpeed: Bool
        public var rateIn: Double
        public var capEnabled: Bool
        public var capBytes: UInt64
        public var perAppSampling: Bool

        public init(statusMode: StatusMode, liveSpeed: Bool, rateIn: Double,
                    capEnabled: Bool, capBytes: UInt64, perAppSampling: Bool) {
            self.statusMode = statusMode
            self.liveSpeed = liveSpeed
            self.rateIn = rateIn
            self.capEnabled = capEnabled
            self.capBytes = capBytes
            self.perAppSampling = perAppSampling
        }
    }

    public static let title = "Data used"
    public static let topAppsTitle = "Top Apps Today"
    public static let topAppsHeader = "Today, by app"
    public static let topAppsLimit = 5
    public static let topAppsNote = "A guide, not an exact split"
    public static let topAppsNoteDetail = "nettop reports totals per process, so a process that quits between samples "
        + "takes its last few seconds with it. The interface counters are the source of truth, and the two will "
        + "not reconcile exactly."

    /// The four totals the menu bar can show, in the order a right-click
    /// cycles through them, each as the menu offers it, with the one showing
    /// now marked. The menu's rows are this choice, so it can be seen, and
    /// made from the keyboard or with VoiceOver, which a right-click cannot be.
    /// On a billing cycle the month is called the cycle.
    public static func periods(current: StatusMode, cal: BytemeterCalendar)
        -> [(mode: StatusMode, title: String, chosen: Bool)] {
        StatusMode.allCases.map { mode in
            let title = mode == .month ? cal.cycleName : mode.label
            return (mode, title, mode == current)
        }
    }

    /// Everything above the submenu and the commands, in order.
    public static func information(_ data: MenuSnapshot, options: Options) -> [MenuLine] {
        var lines: [MenuLine] = [.header(title, trailing: options.liveSpeed ? "↓ " + Units.rate(options.rateIn) : nil)]

        // While the figures below cannot be taken at face value. With a full
        // disk they stop moving and nothing else looks wrong, so the menu says
        // so. The baselines stay put while writes fail, so the next write that
        // succeeds books the traffic in between, as long as the counters have
        // not restarted.
        if let since = data.notRecordingSince {
            lines.append(.warning("Not recording since \(data.cal.timestampLabel(since)): the database cannot be written",
                                  toolTip: "Bytemeter tries again every 5 seconds. Traffic in the meantime is counted "
                                      + "once a write succeeds, unless the Mac restarts first. The reason is in "
                                      + "~/Library/Logs/Bytemeter/bytemeter.err."))
        } else if data.allTime.since == nil {
            // The menu opens by itself two seconds after the first launch,
            // before a byte is booked, so it says why every figure is 0 B.
            lines.append(.warning("Counting has started: the first figures appear within a minute.", toolTip: nil))
        }

        for period in periods(current: options.statusMode, cal: data.cal) {
            let totals: Totals
            let toolTip: String?
            switch period.mode {
            case .today:
                totals = data.today
                toolTip = nil
            case .week:
                totals = data.thisWeek
                toolTip = "From Monday"
            case .month:
                totals = data.thisMonth
                toolTip = "From " + data.cal.dayLabel(data.cal.startOfCycle(data.now))
            case .allTime:
                totals = data.allTime.totals
                toolTip = data.allTime.since.map { "Since \(data.cal.dateLabel($0)) · \(data.allTime.daysText) counted" }
            }
            lines.append(.period(period.mode, label: period.title, down: Units.bytes(totals.bytesIn),
                                 chosen: period.chosen, toolTip: toolTip))
        }

        lines.append(.separator)
        // A cap, when one is set, is the question that matters this month,
        // so it takes the projection's place. Both count download and upload
        // together, as a provider does, and say so in the tooltip.
        if options.capEnabled, options.capBytes > 0 {
            let cap = CapProgress(used: data.thisMonth.total, cap: options.capBytes, now: data.now, cal: data.cal)
            lines.append(.insight(cap.menuText, bar: cap.barFill, toolTip: CapProgress.basis))
        } else {
            lines.append(.insight(data.projection.headline, bar: nil,
                                  toolTip: data.projection.isTooEarly ? ProjectionWording.tooEarlyBasis
                                      : ProjectionWording.basis))
        }
        return lines
    }

    /// Today's top apps by download, under their plain names, or nil while
    /// per-app sampling is off, when the menu leaves the submenu out. They are
    /// the five the dashboard ranks first by download and upload together,
    /// listed here by download, the only figure the menu shows.
    public static func topApps(_ data: MenuSnapshot, options: Options) -> [MenuApp]? {
        guard options.perAppSampling else { return nil }
        let ranked = data.topTalkers.sorted { $0.totals.bytesIn > $1.totals.bytesIn }
        let most = Double(ranked.first?.totals.bytesIn ?? 0)
        return ranked.map { talker in
            MenuApp(name: ProcessNames.plain(talker.name), down: Units.bytes(talker.totals.bytesIn),
                    share: most > 0 ? Double(talker.totals.bytesIn) / most : 0)
        }
    }
}

/// Plain names for the background processes `nettop` reports under names
/// that mean nothing to most people. Only names that are true for every app
/// behind the process: the WebKit networking process loads pages for Mail
/// and every other WebKit app as well as Safari, so it is not called Safari.
/// A process not listed here keeps the name `nettop` gave it.
public enum ProcessNames {
    /// `nettop` reports the kernel's short process name, which stops at 15
    /// characters, so the WebKit process arrives cut short.
    public static let plainNames: [String: String] = [
        "com.apple.WebKi": "Web content (WebKit)",
        "cloudd": "iCloud",
        "nsurlsessiond": "Background downloads",
    ]

    public static func plain(_ process: String) -> String { plainNames[process] ?? process }
}
