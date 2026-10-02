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
    /// Worded once, here, for the menu and the dashboard alike.
    public let projection: ProjectionWording
    public let allTime: AllTimeSummary
    public let cal: BytemeterCalendar
    public let cycleLabel: String
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
        projection = ProjectionWording(projected: forecast.projected, now: now, cal: cal)
        allTime = aggregator.allTime(now: now)
        self.cal = cal
        cycleLabel = cal.cycleLabel(now)

        // Download only, like every headline figure and like the dashboard's
        // busiest hour, so the peak day can never read larger than the month
        // printed above it.
        if let peak = aggregator.peakDownloadHourToday(now: now) {
            peakHourText = String(format: "Peak hour today: %02d:00, ↓ %@", peak.hour, Units.bytes(peak.totals.bytesIn))
        } else {
            peakHourText = "Peak hour today: nothing yet"
        }
        let period = cal.cycleStartDay == 1 ? "this month" : "this cycle"
        if let peak = aggregator.peakDownloadDayThisCycle(now: now) {
            peakDayText = "Peak day \(period): \(peak.label), ↓ \(Units.bytes(peak.totals.bytesIn))"
        } else {
            peakDayText = "Peak day \(period): nothing yet"
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
    public static let hint = "Right-click, two-finger click or Control-click the figure to cycle today, week, month and all time."

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
        lines.append(figure(data.cal.cycleStartDay == 1 ? "Per day this month" : "Per day this cycle", data.perDayMonth))
        if data.allTime.since != nil {
            lines.append(figure("Per day, all time", data.allTime.perDay))
        }

        lines.append(.separator)
        lines.append(.header("Looking ahead"))
        lines.append(.text(data.projection.headline))
        lines.append(.caption(ProjectionWording.basis))
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

// MARK: - Peaks, by download

public extension Aggregator {

    /// The hour today with the most downloaded. Download only, the figure
    /// every headline uses, so a heavy upload cannot make an hour the peak
    /// and then be shown as a download figure it never had.
    func peakDownloadHourToday(now: Date) -> (hour: Int, totals: Totals)? {
        let buckets = hourly(day: now, now: now)
        guard let best = buckets.enumerated().max(by: { $0.element.bytesIn < $1.element.bytesIn }),
              best.element.bytesIn > 0 else { return nil }
        return (best.offset, best.element)
    }

    /// The day so far this month, or this billing cycle, with the most downloaded.
    func peakDownloadDayThisCycle(now: Date) -> LabelledTotals? {
        let start = cal.startOfCycle(now)
        let days = max(1, cal.calendar.dateComponents([.day], from: start, to: now).day.map { $0 + 1 } ?? 1)
        let series = daily(lastDays: days, now: now)
        guard let best = series.max(by: { $0.totals.bytesIn < $1.totals.bytesIn }),
              best.totals.bytesIn > 0 else { return nil }
        return best
    }
}

// MARK: - The projection, worded once

/// What the month is on track for, in the same words on the menu and on the
/// dashboard.
///
/// It is the one figure that adds download and upload together, because a
/// provider's allowance counts both directions, so it says so wherever it
/// appears. And it names the end of the month in words: "by 1 Oct", seen on
/// 29 September, read as if the month ran into October.
public struct ProjectionWording: Equatable {
    /// "100.8 GB", download and upload together.
    public let figure: String
    /// "by the end of September", or "by the end of the cycle, 14 Oct" when a
    /// billing cycle starts on another day.
    public let deadline: String

    /// Said beside the figure wherever it appears.
    public static let basis = "down and up combined, as a provider counts it"

    /// The menu's line. The dashboard shows the same two parts as a tile.
    public var headline: String { "On track for \(figure) \(deadline)" }

    public init(projected: Totals, now: Date, cal: BytemeterCalendar) {
        figure = Units.bytes(projected.total)
        // The cycle ends at the first moment of the next one, so its last
        // day is the day before that.
        let lastDay = cal.addDays(-1, to: cal.endOfCycle(now))
        if cal.cycleStartDay == 1 {
            let f = DateFormatter()
            f.calendar = cal.calendar
            f.timeZone = cal.calendar.timeZone
            f.locale = Locale(identifier: "en_GB")
            f.dateFormat = "MMMM"
            deadline = "by the end of " + f.string(from: lastDay)
        } else {
            deadline = "by the end of the cycle, " + cal.dayLabel(lastDay)
        }
    }
}

// MARK: - Rules the app layer applies to outside text
//
// These sit in the engine, beside the menu's wording, so the self-test can
// check them directly. None of them needs anything from AppKit, and the
// macOS app is the only thing that calls them.

/// One text cell of the CSV export.
public enum CSVCell {

    /// A cell starting with one of these is read by a spreadsheet as a
    /// formula, or has the character skipped before that check. Process names
    /// and network names come from outside, so any of them could be one.
    static let formulaStarts: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]

    /// Quoted, with inner quotes doubled, and with a leading apostrophe on
    /// anything a spreadsheet would treat as a formula, the usual defence
    /// against formula injection. Checked by Unicode scalar, because "\r\n"
    /// is one Character in Swift and would slip past a Character check.
    public static func text(_ value: String) -> String {
        var safe = value
        if let first = safe.unicodeScalars.first, formulaStarts.contains(first) {
            safe = "'" + safe
        }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// The monthly cap as typed into Preferences.
public enum CapInput {

    /// No monthly allowance comes near 100,000 GB, and keeping below it means
    /// the conversion to bytes can never overflow.
    public static let largestGigabytes: Int64 = 100_000
    public static let bytesPerGigabyte: Int64 = 1_000_000_000
    public static let largestBytes: Int64 = largestGigabytes * bytesPerGigabyte

    /// Typed text to a cap in bytes, never above `largestBytes` and never
    /// below zero, and never a trap whatever is typed. Whole or decimal
    /// gigabytes, with an optional "GB" after and commas between thousands.
    /// A number too long to hold is simply above the largest, so it becomes
    /// the largest. Anything else, a sign, an exponent, "inf", is no cap at all.
    public static func bytes(fromText text: String) -> Int64 {
        var digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.lowercased().hasSuffix("gb") {
            digits = String(digits.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        digits = digits.replacingOccurrences(of: ",", with: "")
        guard !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              digits.filter({ $0 == "." }).count <= 1,
              digits.contains(where: { $0.isNumber }),
              let value = Double(digits), value.isFinite
        else { return 0 }
        let gigabytes = min(max(value, 0), Double(largestGigabytes))
        return clamp(Int64((gigabytes * Double(bytesPerGigabyte)).rounded()))
    }

    /// A saved figure, which may have been written by anything, brought into range.
    public static func clamp(_ bytes: Int64) -> Int64 { min(max(bytes, 0), largestBytes) }

    /// What the field shows for a saved cap: "100", "1.5", or empty for none.
    public static func text(forBytes bytes: Int64) -> String {
        let value = clamp(bytes)
        guard value > 0 else { return "" }
        if value % bytesPerGigabyte == 0 { return String(value / bytesPerGigabyte) }
        var text = String(format: "%.2f", Double(value) / Double(bytesPerGigabyte))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "0" ? "0.01" : text
    }
}

// MARK: - Wi-Fi network names

/// What macOS says about Bytemeter using Location Services, which it needs
/// before it will give any app the Wi-Fi network name. The app maps Core
/// Location's own status onto this, so the engine never imports Core Location.
public enum NetworkNamePermission: Equatable {
    case notAsked
    case allowed
    case denied
    case restricted
}

/// The rules for recording network names, kept apart from Core Location so
/// every state can be checked without a permission prompt.
///
/// The box in Preferences is what the user wants; Location Services is what
/// macOS allows. A name is read only when both say yes. macOS is asked only
/// when the user ticks the box or chooses Ask macOS, never at launch, and
/// never while the box is off.
public enum NetworkNames {

    /// Recorded for a minute when the name was not read at all: the box was
    /// off, or macOS had not allowed it yet. The database keeps the plain
    /// placeholder; this is how the dashboard and the export show it.
    public static let notRecorded = "Not recorded"
    /// Recorded when the name was asked for and macOS gave none, for example
    /// with Wi-Fi switched off.
    public static let unknown = "Unknown network"

    public static func displayName(_ stored: String) -> String {
        stored == ssidPlaceholder ? notRecorded : stored
    }

    public enum Status: Equatable {
        /// The box is off.
        case off
        /// The box is on and macOS allows it: names are being recorded.
        case recording
        /// The box was just ticked and macOS is asking; no answer yet.
        case asking
        /// The box is on, but this copy of Bytemeter has not been asked, as
        /// after an update. Nothing asks at launch, so it waits for the user.
        case notAskedYet
        /// macOS does not allow it, so the box has been switched off.
        case refused
        /// Location Services is restricted on this Mac, so the box has been
        /// switched off and cannot be turned on from here.
        case restricted
        /// The box is on, and Location Services was not consulted: the
        /// dashboard built from the command line, which never touches it.
        case unchecked
    }

    /// `permission` is nil when Location Services has not been consulted.
    public static func status(boxTicked: Bool, permission: NetworkNamePermission?, asking: Bool) -> Status {
        switch (boxTicked, permission) {
        case (_, .denied?): return .refused
        case (_, .restricted?): return .restricted
        case (false, _): return .off
        case (true, nil): return .unchecked
        case (true, .allowed?): return .recording
        case (true, .notAsked?): return asking ? .asking : .notAskedYet
        }
    }

    /// The one gate in front of reading the name.
    public static func shouldRead(boxTicked: Bool, permission: NetworkNamePermission?) -> Bool {
        boxTicked && permission == .allowed
    }

    /// Whether ticking the box should ask macOS. Only when it has never been
    /// asked: once it has answered, macOS ignores the request anyway.
    public static func asksOnTick(_ permission: NetworkNamePermission) -> Bool {
        permission == .notAsked
    }

    /// False when the box must be switched back off.
    public static func keepsBoxTicked(_ permission: NetworkNamePermission) -> Bool {
        permission != .denied && permission != .restricted
    }

    /// The button Preferences offers beside the note, if any.
    public enum Action: Equatable {
        case ask
        case openSettings
    }

    public static func action(_ status: Status) -> Action? {
        switch status {
        case .asking, .notAskedYet: return .ask
        case .refused: return .openSettings
        case .off, .recording, .restricted, .unchecked: return nil
        }
    }

    /// Under the box in Preferences, always shown.
    public static let preferencesCaption = "Keeps a home connection separate from a hotspot or a cafe. macOS gives an app "
        + "the Wi-Fi network name only with Location Services permission, so ticking this asks for it. Bytemeter "
        + "reads the network name and nothing else about where the Mac is. While this is off, it does not use "
        + "Location Services at all."

    /// Where permission is granted, in the words of System Settings.
    public static let settingsPath = "System Settings, then Privacy & Security, then Location Services"

    /// The line under the caption saying where things stand, if anything needs saying.
    public static func preferencesNote(_ status: Status) -> String? {
        switch status {
        case .off, .unchecked:
            return nil
        case .recording:
            return "Location Services allows it, so network names are being recorded."
        case .asking:
            return "macOS is asking whether Bytemeter may use Location Services. Network names are recorded once "
                + "you allow it. If no question appeared, choose Ask macOS."
        case .notAskedYet:
            return "Network names are not being recorded yet. macOS has not been asked on this copy of Bytemeter, "
                + "which can happen after an update. Choose Ask macOS to ask now."
        case .refused:
            return "Switched off, because macOS does not allow Bytemeter to use Location Services. To allow it, "
                + "open \(settingsPath), make sure Location Services is on, and switch on Bytemeter in the list. "
                + "Then tick this box again."
        case .restricted:
            return "Switched off, because Location Services is restricted on this Mac, for example by a "
                + "management profile, so it cannot be allowed from here."
        }
    }

    /// The "Per network" note on the dashboard, describing what was actually recorded.
    public static func dashboardNote(_ status: Status) -> String {
        let legend = "\(notRecorded) covers minutes when the name was not read: before recording was switched on, "
            + "or while macOS did not allow it. \(unknown) means macOS gave no name, for example while Wi-Fi was off."
        switch status {
        case .off:
            return "Network name recording is off, so traffic is not split by network. Switching it on in "
                + "Preferences asks macOS for Location Services, which macOS requires before it gives any app a "
                + "Wi-Fi network name. While it is off, Bytemeter does not use Location Services at all."
        case .recording, .unchecked:
            return "Each minute is recorded against the Wi-Fi network the Mac was on. " + legend
        case .asking, .notAskedYet:
            return "Network name recording is switched on, but macOS has not yet allowed Bytemeter to use "
                + "Location Services, so new minutes are \(notRecorded.lowercased()). Preferences can ask again. "
                + legend
        case .refused:
            return "Network name recording was switched off because macOS does not allow Bytemeter to use "
                + "Location Services. Preferences says where to allow it."
        case .restricted:
            return "Network name recording was switched off because Location Services is restricted on this Mac."
        }
    }
}
