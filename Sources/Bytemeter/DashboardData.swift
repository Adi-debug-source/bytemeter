import Foundation
import BytemeterCore

/// Everything the dashboard shows, gathered in one pass on the database queue
/// so the page generator itself is pure string work.
struct DashboardData {
    let generatedAt: Date
    let cal: BytemeterCalendar

    let today: Totals
    let yesterday: Totals
    let thisWeek: Totals
    let last7: Totals
    let thisMonth: Totals
    let last30: Totals
    let allTime: AllTimeSummary
    /// The first day of this month, or of the billing cycle if one is set.
    let cycleStart: Date

    let hourly: [Totals]
    let daily: [LabelledTotals]
    let rollingAverage: [Double?]
    let heat: [HeatCell]
    let monthly: [LabelledTotals]

    let topTalkersToday: [TopTalker]
    let topTalkersMonth: [TopTalker]
    let idleTotals: Totals
    let activeTotals: Totals
    let byInterface: [(String, Totals)]
    let bySSID: [(String, Totals)]

    /// Download and upload together, worded as the menu words it.
    let projection: ProjectionWording
    /// Both by download, as the menu has them.
    let peakHour: (hour: Int, totals: Totals)?
    let peakDay: LabelledTotals?

    let ssidCapture: Bool
    /// Where recording network names stands, for the "Per network" note.
    let networkNames: NetworkNames.Status
    let perAppSampling: Bool
    let capEnabled: Bool
    let capBytes: UInt64
    let counterSource: String
    let countingSince: Date?
    let events: [(ts: Int64, kind: String, detail: String)]

    /// `networkNames` comes from the running app, which knows what macOS has
    /// said. Without it, as from the command line, Location Services is not
    /// consulted and the note only says whether the box is on.
    init(aggregator: Aggregator, settings: Settings, now: Date, networkNames: NetworkNames.Status? = nil) {
        generatedAt = now
        cal = aggregator.cal

        today = aggregator.totals(cal.today(now))
        yesterday = aggregator.totals(cal.yesterday(now))
        thisWeek = aggregator.totals(cal.thisWeek(now))
        last7 = aggregator.totals(cal.rollingDays(7, now: now))
        thisMonth = aggregator.totals(cal.thisCycle(now))
        last30 = aggregator.totals(cal.rollingDays(30, now: now))
        allTime = aggregator.allTime(now: now)
        cycleStart = cal.startOfCycle(now)

        hourly = aggregator.hourly(day: now, now: now)
        let series = aggregator.daily(lastDays: 30, now: now)
        daily = series

        // A seven day rolling mean over the download figures, drawn over the
        // bars so a single heavy day does not read as a trend.
        var averages: [Double?] = []
        for index in series.indices {
            guard index >= 6 else { averages.append(nil); continue }
            let window = series[(index - 6)...index]
            let sum = window.reduce(0.0) { $0 + Double($1.totals.bytesIn) }
            averages.append(sum / 7.0)
        }
        rollingAverage = averages

        heat = aggregator.heatmap(lastDays: 30, now: now)
        monthly = aggregator.monthly(now: now)

        topTalkersToday = aggregator.topTalkers(cal.today(now), limit: 10)
        topTalkersMonth = aggregator.topTalkers(cal.thisCycle(now), limit: 10)

        let split = aggregator.idleSplit(cal.rollingDays(30, now: now))
        idleTotals = split.idle
        activeTotals = split.active

        byInterface = aggregator.byInterface(cal.rollingDays(30, now: now))
        bySSID = aggregator.bySSID(cal.rollingDays(30, now: now))

        projection = ProjectionWording(projected: aggregator.projection(now: now).projected, now: now, cal: cal)
        peakHour = aggregator.peakDownloadHourToday(now: now)
        peakDay = aggregator.peakDownloadDayThisCycle(now: now)

        ssidCapture = settings.ssidCapture
        self.networkNames = networkNames
            ?? NetworkNames.status(boxTicked: settings.ssidCapture, permission: nil, asking: false)
        perAppSampling = settings.perAppSampling
        capEnabled = settings.capEnabled
        capBytes = UInt64(max(0, settings.capBytes))
        counterSource = aggregator.db.state(StateKey.counterSource) ?? "unknown"
        countingSince = allTime.since

        var rows: [(ts: Int64, kind: String, detail: String)] = []
        // Only what had happened by `now`, so a page drawn as of an earlier
        // moment does not list events from after it.
        try? aggregator.db.query("SELECT ts, kind, detail FROM events WHERE ts<=? ORDER BY ts DESC LIMIT 10;",
                                 [.int(Int64(now.timeIntervalSince1970))]) { row in
            rows.append((row.int(0), row.string(1), row.string(2)))
        }
        events = rows
    }
}
