import Foundation

/// One line of the status item's menu, before anything draws it.
///
/// What the menu says is worked out here, in the shared engine, as plain
/// values: the macOS app draws each line with a view, and the self-test reads
/// exactly what the menu would show, including which rows are full contrast,
/// without opening a menu. The demo mode and the real app build their menus
/// through this same code, so the demo cannot drift from the real thing.
public enum MenuLine: Equatable {
    case header(String)
    /// `strong` is true for exactly the four totals the menu bar figure cycles
    /// through, which are drawn in full contrast; every other row is grey.
    case figure(label: String, down: String, up: String, strong: Bool)
    case text(String, toolTip: String? = nil)
    /// A small grey line belonging to the row above it.
    case caption(String)
    case separator
}

/// Everything the menu needs, gathered in one pass on the database queue.
/// The totals, the projection and the peaks come from `Headlines`, the same
/// figures the dashboard and the menu bar show.
public struct MenuSnapshot {
    public let today: Totals
    public let yesterday: Totals
    public let thisWeek: Totals
    public let last7: Totals
    public let thisMonth: Totals
    public let last30: Totals
    public let perHourToday: Totals
    public let perDayWeek: Totals
    public let perDayMonth: Totals
    /// Worded once, in `Headlines`, for the menu and the dashboard alike.
    public let projection: ProjectionWording
    public let allTime: AllTimeSummary
    public let cal: BytemeterCalendar
    /// The moment described, for the figures that count days from it.
    public let now: Date
    public let cycleLabel: String
    public let peakHourText: String
    public let peakDayText: String
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
        yesterday = headlines.yesterday
        thisWeek = headlines.thisWeek
        last7 = headlines.last7
        thisMonth = headlines.thisMonth
        last30 = headlines.last30
        perHourToday = aggregator.averagePerHourToday(now: now)
        perDayWeek = aggregator.averagePerDay(cal.thisWeek(now), now: now)
        perDayMonth = aggregator.averagePerDay(cal.thisCycle(now), now: now)

        projection = headlines.projection
        allTime = headlines.allTime
        self.cal = cal
        self.now = now
        cycleLabel = cal.cycleLabel(now)

        // The peaks are by download, so they are marked ↓.
        if let peak = headlines.peakHour {
            peakHourText = String(format: "Peak hour today: %02d:00, ↓ %@", peak.hour, Units.bytes(peak.totals.bytesIn))
        } else {
            peakHourText = "Peak hour today: nothing yet"
        }
        let period = cal.cycleStartDay == 1 ? "this month" : "this cycle"
        if let peak = headlines.peakDay {
            peakDayText = "Peak day \(period): \(peak.label), ↓ \(Units.bytes(peak.totals.bytesIn))"
        } else {
            peakDayText = "Peak day \(period): nothing yet"
        }
        topTalkers = aggregator.topTalkers(cal.today(now), limit: 5)
        notRecordingSince = aggregator.db.failingSince
    }
}

public enum MenuModel {

    /// The settings that change what the menu shows.
    public struct Options {
        public var liveSpeed: Bool
        public var rateIn: Double
        public var rateOut: Double
        public var capEnabled: Bool
        public var capBytes: UInt64
        public var perAppSampling: Bool

        public init(liveSpeed: Bool, rateIn: Double, rateOut: Double,
                    capEnabled: Bool, capBytes: UInt64, perAppSampling: Bool) {
            self.liveSpeed = liveSpeed
            self.rateIn = rateIn
            self.rateOut = rateOut
            self.capEnabled = capEnabled
            self.capBytes = capBytes
            self.perAppSampling = perAppSampling
        }
    }

    /// Shown under the actions, wrapped to the width of the figures.
    public static let hint = "Right-click, two-finger click or Control-click the figure to cycle today, week, month and all time."

    /// Everything above the actions, in order.
    public static func information(_ data: MenuSnapshot, options: Options) -> [MenuLine] {
        var lines: [MenuLine] = []
        func figure(_ label: String, _ totals: Totals, strong: Bool = false) -> MenuLine {
            .figure(label: label, down: Units.bytes(totals.bytesIn), up: Units.bytes(totals.bytesOut), strong: strong)
        }

        // With a full disk the figures below stop moving and nothing else
        // looks wrong, so the first line says so. The baselines stay put
        // while writes fail, so the next write that succeeds books the
        // traffic in between, as long as the counters have not restarted.
        if let since = data.notRecordingSince {
            lines.append(.text("Not recording since \(data.cal.timestampLabel(since)): the database cannot be written",
                               toolTip: "Bytemeter tries again every 5 seconds. Traffic in the meantime is counted "
                                   + "once a write succeeds, unless the Mac restarts first. The reason is in "
                                   + "~/Library/Logs/Bytemeter/bytemeter.err."))
            lines.append(.separator)
        }

        if options.liveSpeed {
            lines.append(.header("Live"))
            lines.append(.figure(label: "Now", down: Units.rate(options.rateIn), up: Units.rate(options.rateOut),
                                 strong: false))
            lines.append(.separator)
        }

        // Strong rows are the four totals the menu bar figure cycles through,
        // so the menu and the figure point at each other; the rest is grey.
        lines.append(.header("Totals"))
        lines.append(figure("Today", data.today, strong: true))
        lines.append(figure("Yesterday", data.yesterday))
        lines.append(figure("This week, from Monday", data.thisWeek, strong: true))
        lines.append(figure("Last 7 days", data.last7))
        lines.append(figure(data.cycleLabel, data.thisMonth, strong: true))
        lines.append(figure("Last 30 days", data.last30))
        if let since = data.allTime.since {
            lines.append(figure("All time", data.allTime.totals, strong: true))
            lines.append(.caption("since \(data.cal.dateLabel(since)) · \(data.allTime.daysText) counted"))
        }

        lines.append(.separator)
        lines.append(.header("Averages"))
        lines.append(figure("Per hour today", data.perHourToday))
        lines.append(figure("Per day this week", data.perDayWeek))
        lines.append(figure(data.cal.cycleStartDay == 1 ? "Per day this month" : "Per day this cycle", data.perDayMonth))
        if data.allTime.since != nil {
            lines.append(figure("Per day, all time", data.allTime.perDay))
        }

        lines.append(.separator)
        lines.append(.header("Looking ahead"))
        lines.append(.text(data.projection.headline))
        lines.append(.caption(data.projection.isTooEarly ? ProjectionWording.tooEarlyBasis : ProjectionWording.basis))
        lines.append(.text(data.peakHourText))
        lines.append(.text(data.peakDayText))

        // Shown only when a cap is set in Preferences; off by default.
        if options.capEnabled, options.capBytes > 0 {
            let cap = CapProgress(used: data.thisMonth.total, cap: options.capBytes, now: data.now, cal: data.cal)
            lines.append(.separator)
            lines.append(.header("Cap"))
            lines.append(.text(cap.menuText))
            lines.append(.caption(cap.remainingText))
        }

        lines.append(.separator)
        if options.perAppSampling {
            lines.append(.header("Top talkers today"))
            if data.topTalkers.isEmpty {
                lines.append(.text("Nothing recorded yet"))
            } else {
                for talker in data.topTalkers {
                    lines.append(figure(talker.name, talker.totals))
                }
            }
            lines.append(.text("A guide, not an exact split. See the dashboard.",
                               toolTip: "nettop reports totals per process, so a process that quits between samples "
                                   + "takes its last few seconds with it. The interface counters are the source of "
                                   + "truth, and the two will not reconcile exactly."))
        } else {
            lines.append(.text("Per-app sampling is off"))
        }
        return lines
    }
}
