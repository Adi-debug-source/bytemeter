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
    public let projected: Totals
    public let allTime: AllTimeSummary
    public let cal: BytemeterCalendar
    public let cycleLabel: String
    public let cycleEndLabel: String
    public let peakHourText: String
    public let peakDayText: String
    public let topTalkers: [TopTalker]

    /// `now` is the moment the menu describes: the clock for the real app, or
    /// a fixed moment for a demo or a test.
    public init(aggregator: Aggregator, now: Date) {
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
    public static let hint = "Right-click or two-finger click the figure to cycle today, week, month and all time."

    /// Everything above the actions, in order.
    public static func information(_ data: MenuSnapshot, options: Options) -> [MenuLine] {
        var lines: [MenuLine] = []
        func figure(_ label: String, _ totals: Totals, strong: Bool = false) -> MenuLine {
            .figure(label: label, down: Units.bytes(totals.bytesIn), up: Units.bytes(totals.bytesOut), strong: strong)
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
        lines.append(figure("Per day this month", data.perDayMonth))
        if data.allTime.since != nil {
            lines.append(figure("Per day, all time", data.allTime.perDay))
        }

        lines.append(.separator)
        lines.append(.header("Looking ahead"))
        lines.append(.text("At that rate, \(data.cycleEndLabel) ends at \(Units.bytes(data.projected.total))"))
        lines.append(.text(data.peakHourText))
        lines.append(.text(data.peakDayText))

        // Cap machinery: present and wired, switched off. When a cap is turned
        // on, this is the progress bar that appears, with no rebuild needed.
        if options.capEnabled, options.capBytes > 0 {
            lines.append(.separator)
            lines.append(.header("Cap"))
            lines.append(.text(capBarText(used: data.thisMonth.total, cap: options.capBytes)))
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

    public static func capBarText(used: UInt64, cap: UInt64) -> String {
        let fraction = cap == 0 ? 0 : min(1.0, Double(used) / Double(cap))
        let filled = Int((fraction * 12).rounded())
        let bar = String(repeating: "▰", count: filled) + String(repeating: "▱", count: 12 - filled)
        return "\(bar)  \(Int(fraction * 100))% of \(Units.bytes(cap))"
    }
}
