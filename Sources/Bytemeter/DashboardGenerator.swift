import Foundation
import BytemeterCore

/// Builds the dark dashboard as one self contained HTML file.
///
/// Every chart is hand rolled inline SVG. There is no CDN, no external
/// stylesheet and no script, and the two typefaces travel inside the page as
/// data (`DashboardFonts`), so it makes no network requests at all: the page
/// opens and renders with the network switched off, which is the only honest
/// way to build a tool that measures network use.
enum DashboardGenerator {

    /// The page and its CSV are written side by side under these names, and
    /// the page's export link points at the CSV by name.
    static let pageFile = "dashboard.html"
    static let csvFile = "bytemeter_export.csv"

    static func write(data: DashboardData, folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = folder.appendingPathComponent(pageFile)
        let csv = folder.appendingPathComponent(csvFile)
        try html(data).write(to: page, atomically: true, encoding: .utf8)
        try csvExport(data).write(to: csv, atomically: true, encoding: .utf8)
        return page
    }

    // MARK: - Page

    /// The sections in page order. A section with nothing to show, such as
    /// the cap with no cap set, adds nothing.
    static func html(_ data: DashboardData) -> String {
        let sections = [masthead(data), hero(data), capPanel(data), hourlyPanel(data), dailyPanel(data),
                        heatmapPanel(data), splitsRow(data), monthlyPanel(data), footer(data)]
        return page(body: sections.joined())
    }

    // MARK: - Sections

    private static func masthead(_ data: DashboardData) -> String {
        let since = data.allTime.since.map { data.cal.timestampLabel($0) } ?? "just now"
        return """
        <header class="masthead">
          <div class="brand">Bytemeter</div>
          <div class="meta">\(esc(data.cal.timestampLabel(data.generatedAt)))<br>
          <span class="muted">Counting since \(esc(since))</span></div>
        </header>
        """
    }

    /// Today's figure, then the wider picture beside it.
    private static func hero(_ data: DashboardData) -> String {
        let cal = data.cal
        let figure = heroParts(data.today.bytesIn)
        let projectionBasis = data.projection.isTooEarly ? ProjectionWording.tooEarlyBasis : ProjectionWording.basis
        let comparison = DayComparison.text(today: data.today, yesterdaySoFar: data.yesterdaySoFar, yesterday: data.yesterday)
        return """
        <section class="hero">
          <div class="hero-main">
            <div class="eyebrow">Today, \(esc(cal.fullDayLabel(data.generatedAt)))</div>
            <div class="hero-figure"><span class="value">\(esc(figure.number))</span><span class="unit">\(esc(figure.unit))</span></div>
            <div class="hero-sub">downloaded<span class="sep">·</span>\(esc(Units.bytes(data.today.bytesOut))) uploaded</div>
            <div class="hero-compare">\(esc(comparison))</div>
          </div>
          <dl class="hero-stats">
            \(statRow("This week, from Monday", data.thisWeek))
            \(statRow("Last 7 days", data.last7))
            \(statRow(cal.cycleLabel(data.generatedAt), data.thisMonth))
            \(statRow("Last 30 days", data.last30))
            <div class="stat projection">
              <dt>On track for<span class="since">\(esc(projectionBasis))</span></dt>
              <dd>\(esc(data.projection.figure))<span class="qualifier">\(esc(data.projection.deadline))</span></dd>
            </div>
            \(allTimeRow(data))
          </dl>
        </section>
        """
    }

    /// Only while a cap is set.
    private static func capPanel(_ data: DashboardData) -> String {
        guard data.capEnabled, data.capBytes > 0 else { return "" }
        let used = data.thisMonth.total
        let cap = data.capBytes
        let fraction = cap == 0 ? 0 : min(1.0, Double(used) / Double(cap))
        return """
        <section class="panel cap">
          <div class="panel-head"><h2>Monthly cap</h2>
            <p class="note">\(esc(Units.bytes(used))) of \(esc(Units.bytes(cap))) used.</p></div>
          <div class="capbar"><span style="width:\(String(format: "%.1f", fraction * 100))%"></span></div>
        </section>
        """
    }

    private static func hourlyPanel(_ data: DashboardData) -> String {
        let hourValues = data.hourly.enumerated().map { (label: String(format: "%02d", $0.offset), totals: $0.element) }
        return """
        <section class="panel">
          <div class="panel-head">
            <h2>Today by hour</h2>
            <p class="note">\(esc(peakHourNote(data)))</p>
          </div>
          \(SVGKit.mirroredBars(id: "hourly", values: hourValues, labelEvery: 2) { index in
              let totals = data.hourly[index]
              return "\(SVGKit.hourSpan(index)), down \(Units.bytes(totals.bytesIn)), "
                   + "up \(Units.bytes(totals.bytesOut))." + estimateNote(totals)
          })
          \(downUpLegend(estimated: SVGKit.barsShowEstimate(hourValues)))
        </section>
        """
    }

    private static func dailyPanel(_ data: DashboardData) -> String {
        let cal = data.cal
        let dayValues = data.daily.map { (label: $0.label, totals: $0.totals) }
        return """
        <section class="panel">
          <div class="panel-head">
            <h2>Last 30 days</h2>
            <p class="note">The dashed line averages the seven whole days up to each day, so one heavy day does not read as a trend. It starts once a week has been counted and stops at yesterday, because today is not over yet.</p>
          </div>
          \(SVGKit.mirroredBars(id: "daily", values: dayValues, labelEvery: 3, rollingAverage: data.rollingAverage) { index in
              let entry = data.daily[index]
              if let since = data.allTime.since, cal.startOfDay(entry.date, offsetBy: 1) <= since {
                  return "\(cal.fullDayLabel(entry.date)): before Bytemeter started counting."
              }
              return "\(cal.fullDayLabel(entry.date)), down \(Units.bytes(entry.totals.bytesIn)), "
                   + "up \(Units.bytes(entry.totals.bytesOut))." + estimateNote(entry.totals)
          })
          \(downUpLegend(averages: data.rollingAverage, estimated: SVGKit.barsShowEstimate(dayValues)))
        </section>
        """
    }

    /// Given the most room, because it answers the most useful question.
    private static func heatmapPanel(_ data: DashboardData) -> String {
        let heatPeak = data.heat.map(\.average.total).max() ?? 0
        return """
        <section class="panel feature">
          <div class="panel-head">
            <h2>When the data actually goes</h2>
            <p class="note">Day of the week against hour of the day, as an average over the last four whole weeks. Darker is quieter.</p>
          </div>
          <div class="heat-wrap">\(SVGKit.heatmap(id: "heat", cells: data.heat) { estimateNote($0.average) })</div>
          \(SVGKit.heatLegend(peak: heatPeak, estimateKey: SVGKit.heatShowsEstimate(data.heat)
              ? "<span class=\"key est-key\"><i class=\"swatch heat-est\"></i>Hatched from the bottom: the estimated "
                + "share. \(asleepLine)</span>"
              : ""))
        </section>
        """
    }

    /// Top talkers beside the smaller splits.
    private static func splitsRow(_ data: DashboardData) -> String {
        """
        <div class="row">
          <section class="panel">
            <div class="panel-head">
              <h2>Top talkers</h2>
              <p class="note">\(esc(topTalkerNote(data)))</p>
            </div>
            \(talkerTable(today: data.topTalkersToday, month: data.topTalkersMonth))
          </section>
          <section class="panel side">
            <div class="panel-head"><h2>Idle against active</h2>
              <p class="note">Idle means no keyboard or trackpad input for five minutes or more, over the last 30 days.</p>
            </div>
            \(SVGKit.splitBar(activeBytes: data.activeTotals.total, idleBytes: data.idleTotals.total))
            <dl class="mini">
              \(miniRow("Active", data.activeTotals.total, of: data.activeTotals.total &+ data.idleTotals.total))
              \(miniRow("Idle", data.idleTotals.total, of: data.activeTotals.total &+ data.idleTotals.total))
            </dl>
            <div class="panel-head tight"><h2>Per interface</h2></div>
            \(breakdownList(data.byInterface))
            <div class="panel-head tight"><h2>Per network</h2></div>
            \(networkSection(data))
          </section>
        </div>
        """
    }

    /// Only once a second month has begun.
    private static func monthlyPanel(_ data: DashboardData) -> String {
        guard data.monthly.count > 1 else { return "" }
        let monthValues = data.monthly.map { (label: $0.label, totals: $0.totals) }
        return """
        <section class="panel">
          <div class="panel-head"><h2>Month by month</h2></div>
          \(SVGKit.mirroredBars(id: "monthly", values: monthValues, labelEvery: 1) { index in
              let entry = data.monthly[index]
              return "\(entry.label), down \(Units.bytes(entry.totals.bytesIn)), "
                   + "up \(Units.bytes(entry.totals.bytesOut))." + estimateNote(entry.totals)
          })
        </section>
        """
    }

    /// How the numbers were made, and what happened.
    private static func footer(_ data: DashboardData) -> String {
        """
        <footer>
          <div class="foot-grid">
            <div>
              <h3>How these numbers are made</h3>
              <p>Interface byte counters are read every five seconds and the difference is added to a one minute
              bucket. Every other figure on this page is worked out from those buckets when the page is built, so
              the hour, day, week and month totals cannot disagree with each other.</p>
              <p>Only physical interfaces are counted, so a VPN tunnel is never added on top of the Wi-Fi traffic
              it is already carrying. Units are decimal: 1 GB is 1,000,000,000 bytes, the way routers and
              internet providers count.</p>
              <p>While the Mac sleeps, or Bytemeter is not running, the counters keep counting but nobody reads
              them. The difference at the next reading is real traffic and every total includes it, but it cannot
              be pinned to particular minutes, so it is spread evenly across the gap and drawn hatched. After a
              restart the same applies from the moment the Mac started.</p>
              <p>All time means since Bytemeter started counting. Whatever the Mac had already carried before
              then has no timestamps, so it is left out rather than guessed at.</p>
              <p class="muted">Counter source: \(esc(data.counterSource == "mib64" ? "64 bit interface MIB" : data.counterSource)).</p>
            </div>
            <div>
              <h3>Recent events</h3>
              \(eventList(data))
            </div>
          </div>
          <div class="foot-bar">
            <a class="export" href="\(csvFile)" download>Export CSV</a>
            <span class="muted">Generated by Bytemeter on this Mac. Nothing here has left the machine.</span>
          </div>
        </footer>
        """
    }

    // MARK: - Fragments

    private static func statRow(_ label: String, _ totals: Totals) -> String {
        """
        <div class="stat">
          <dt>\(esc(label))</dt>
          <dd>\(esc(Units.bytes(totals.bytesIn)))<span class="qualifier">up \(esc(Units.bytes(totals.bytesOut)))</span></dd>
        </div>
        """
    }

    /// The running total since counting began, set apart as the last row.
    private static func allTimeRow(_ data: DashboardData) -> String {
        guard let since = data.allTime.since else { return "" }
        let all = data.allTime
        return """
        <div class="stat alltime">
          <dt>All time<span class="since">since \(esc(data.cal.dateLabel(since))) · \(esc(all.daysText))</span></dt>
          <dd>\(esc(Units.bytes(all.totals.bytesIn)))<span class="qualifier">up \(esc(Units.bytes(all.totals.bytesOut))) \
        · \(esc(Units.bytes(all.perDay.bytesIn))) down a day</span></dd>
        </div>
        """
    }

    /// The one plain-language line that explains every hatched mark.
    private static let asleepLine = "The Mac was asleep or Bytemeter was not running, "
        + "so the traffic across that gap is spread evenly over it."

    /// Added to a tooltip when part of the figure was spread across a gap.
    private static func estimateNote(_ totals: Totals) -> String {
        guard totals.estimatedTotal > 0 else { return "" }
        return " Of this, \(Units.bytes(totals.estimatedIn)) down and \(Units.bytes(totals.estimatedOut)) up is estimated: "
             + "the Mac was asleep or Bytemeter was not running, so it is spread evenly across the gap."
    }

    private static func miniRow(_ label: String, _ value: UInt64, of total: UInt64) -> String {
        let share = total == 0 ? 0 : Int((Double(value) / Double(total) * 100).rounded())
        return """
        <div><dt>\(esc(label))</dt><dd>\(esc(Units.bytes(value)))<span class="qualifier">\(share)%</span></dd></div>
        """
    }

    /// The key under a bar chart. `averages` is the chart's rolling average,
    /// keyed only when the line is drawn.
    private static func downUpLegend(averages: [Double?] = [], estimated: Bool) -> String {
        var items = """
        <span class="key"><i class="swatch solid"></i>Down, above the line</span>
        <span class="key"><i class="swatch soft"></i>Up, below the line, on the same scale</span>
        """
        if SVGKit.drawsAverage(averages) {
            items += "<span class=\"key\"><i class=\"swatch dash\"></i>Seven day average</span>"
        }
        // Only on a chart that draws some, so a clean day carries no clutter.
        if estimated {
            items += "<span class=\"key est-key\"><i class=\"swatch est\"></i>Hatched: estimated. \(asleepLine)</span>"
        }
        return "<div class=\"legend keys\">\(items)</div>"
    }

    private static func talkerTable(today: [TopTalker], month: [TopTalker]) -> String {
        func rows(_ talkers: [TopTalker]) -> String {
            guard !talkers.isEmpty else {
                return "<tr><td colspan=\"4\" class=\"empty\">Nothing recorded yet.</td></tr>"
            }
            let peak = talkers.map(\.totals.total).max() ?? 1
            return talkers.map { talker in
                let share = peak == 0 ? 0 : Double(talker.totals.total) / Double(peak) * 100
                return """
                <tr>
                  <td class="name">\(esc(talker.name))</td>
                  <td class="num">\(esc(Units.bytes(talker.totals.bytesIn)))</td>
                  <td class="num quiet">\(esc(Units.bytes(talker.totals.bytesOut)))</td>
                  <td class="share"><span style="width:\(String(format: "%.1f", share))%"></span></td>
                </tr>
                """
            }.joined()
        }
        func table(_ caption: String, _ talkers: [TopTalker]) -> String {
            """
              <table><caption>\(esc(caption))</caption>
                <thead><tr><th>Process</th><th class="num">Down</th><th class="num">Up</th><th></th></tr></thead>
                <tbody>\(rows(talkers))</tbody>
              </table>
            """
        }
        return """
        <div class="tables">
        \(table("Today", today))
        \(table("This month", month))
        </div>
        """
    }

    private static func breakdownList(_ entries: [(String, Totals)]) -> String {
        guard !entries.isEmpty else { return "<p class=\"note\">Nothing recorded yet.</p>" }
        let total = entries.reduce(UInt64(0)) { $0 &+ $1.1.total }
        return "<dl class=\"mini\">" + entries.map { entry in
            miniRow(entry.0, entry.1.total, of: total)
        }.joined() + "</dl>"
    }

    /// The note always says what was really recorded; the list follows only
    /// while the box is on, with the placeholder shown in words.
    private static func networkSection(_ data: DashboardData) -> String {
        let note = "<p class=\"note\">\(esc(NetworkNames.dashboardNote(data.networkNames)))</p>"
        guard data.ssidCapture else { return note }
        let named = data.bySSID.map { (NetworkNames.displayName($0.0), $0.1) }
        return note + breakdownList(named)
    }

    private static func eventList(_ data: DashboardData) -> String {
        guard !data.events.isEmpty else { return "<p class=\"note\">Nothing to report.</p>" }
        return "<ul class=\"events\">" + data.events.map { event in
            let when = data.cal.timestampLabel(Date(timeIntervalSince1970: TimeInterval(event.ts)))
            return "<li><span class=\"when\">\(esc(when))</span><span class=\"kind\">\(esc(event.kind))</span>"
                 + "<span class=\"detail\">\(esc(event.detail))</span></li>"
        }.joined() + "</ul>"
    }

    private static func peakHourNote(_ data: DashboardData) -> String {
        guard let peak = data.peakHour else { return "Nothing recorded yet today." }
        return "Busiest hour so far: \(SVGKit.hourSpan(peak.hour)), \(Units.bytes(peak.totals.bytesIn)) down."
    }

    private static func topTalkerNote(_ data: DashboardData) -> String {
        guard data.perAppSampling else { return "Per-app sampling is switched off in Preferences." }
        return "A good guide, not an exact split. Per-process figures come from nettop, so a process that quits "
             + "between samples takes its last few seconds with it. The interface counters are the source of "
             + "truth, and the two will not add up to exactly the same number."
    }

    private static func heroParts(_ bytes: UInt64) -> (number: String, unit: String) {
        let text = Units.bytes(bytes)
        let parts = text.split(separator: " ")
        return (String(parts.first ?? "0"), String(parts.count > 1 ? parts[1] : "B"))
    }

    private static func esc(_ text: String) -> String { SVGKit.escape(text) }

    // MARK: - CSV

    /// Long format on purpose: one shape of row, so it drops straight into a
    /// spreadsheet or a script without any unpicking of sections.
    static func csvExport(_ data: DashboardData) -> String {
        var lines = ["scope,label,bytes_in,bytes_out,total_gb"]
        // Every label goes through CSVCell: process and network names come
        // from outside and could be written to run as a spreadsheet formula.
        func add(_ scope: String, _ label: String, _ totals: Totals) {
            lines.append("\(scope),\(CSVCell.text(label)),\(totals.bytesIn),\(totals.bytesOut),"
                       + String(format: "%.6f", Units.gigabytes(totals.total)))
        }
        for (index, totals) in data.hourly.enumerated() {
            add("hour_today", String(format: "%02d:00", index), totals)
        }
        for entry in data.daily { add("day", data.cal.fullDayLabel(entry.date), entry.totals) }
        for entry in data.monthly { add("month", entry.label, entry.totals) }
        if let since = data.allTime.since {
            add("all_time", "Since \(data.cal.dateLabel(since))", data.allTime.totals)
        }
        for talker in data.topTalkersToday { add("process_today", talker.name, talker.totals) }
        for talker in data.topTalkersMonth { add("process_month", talker.name, talker.totals) }
        for entry in data.byInterface { add("interface_30d", entry.0, entry.1) }
        for entry in data.bySSID { add("network_30d", NetworkNames.displayName(entry.0), entry.1) }
        add("idle_30d", "Idle", data.idleTotals)
        add("idle_30d", "Active", data.activeTotals)
        return lines.joined(separator: "\n") + "\n"
    }
}
