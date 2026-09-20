import Foundation
import BytemeterCore

/// Builds the dark dashboard as one self contained HTML file.
///
/// Every chart is hand rolled inline SVG. There is no CDN, no external
/// stylesheet, no web font and no script: the page opens and renders with the
/// network switched off, which is the only honest way to build a tool that
/// measures network use.
enum DashboardGenerator {

    static func write(data: DashboardData, folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = folder.appendingPathComponent("dashboard.html")
        let csv = folder.appendingPathComponent("bytemeter_export.csv")
        try html(data).write(to: page, atomically: true, encoding: .utf8)
        try csvExport(data).write(to: csv, atomically: true, encoding: .utf8)
        return page
    }

    // MARK: - Page

    static func html(_ data: DashboardData) -> String {
        let cal = data.cal
        let hero = heroParts(data.today.bytesIn)
        let since = data.countingSince.map { cal.timestampLabel($0) } ?? "just now"

        let hourValues = data.hourly.enumerated().map { (label: String(format: "%02d", $0.offset), totals: $0.element) }
        let dayValues = data.daily.map { (label: $0.label, totals: $0.totals) }
        let heatPeak = data.heat.map(\.totals.total).max() ?? 0

        var body = ""

        // Masthead
        body += """
        <header class="masthead">
          <div class="brand">Bytemeter</div>
          <div class="meta">\(esc(cal.timestampLabel(data.generatedAt)))<br>
          <span class="muted">Counting since \(esc(since))</span></div>
        </header>
        """

        // Hero: today's figure, then the wider picture beside it.
        body += """
        <section class="hero">
          <div class="hero-main">
            <div class="eyebrow">Today, \(esc(cal.fullDayLabel(data.generatedAt)))</div>
            <div class="hero-figure"><span class="value">\(esc(hero.number))</span><span class="unit">\(esc(hero.unit))</span></div>
            <div class="hero-sub">downloaded<span class="sep">·</span>\(esc(Units.bytes(data.today.bytesOut))) uploaded</div>
            <div class="hero-compare">\(esc(comparisonText(today: data.today, yesterday: data.yesterday)))</div>
          </div>
          <dl class="hero-stats">
            \(statRow("This week, from Monday", data.thisWeek))
            \(statRow("Last 7 days", data.last7))
            \(statRow("This month", data.thisMonth))
            \(statRow("Last 30 days", data.last30))
            <div class="stat projection">
              <dt>On track for</dt>
              <dd>\(esc(Units.bytes(data.projected.total)))<span class="qualifier">by \(esc(cal.dayLabel(data.cycleEnd)))</span></dd>
            </div>
          </dl>
        </section>
        """

        if data.capEnabled, data.capBytes > 0 {
            body += capPanel(used: data.thisMonth.total, cap: data.capBytes)
        }

        // Today by hour
        body += """
        <section class="panel">
          <div class="panel-head">
            <h2>Today by hour</h2>
            <p class="note">\(esc(peakHourNote(data)))</p>
          </div>
          \(SVGKit.mirroredBars(values: hourValues, labelEvery: 2) { index in
              let totals = data.hourly[index]
              return String(format: "%02d:00 to %02d:00, down %@, up %@", index, (index + 1) % 24,
                            Units.bytes(totals.bytesIn), Units.bytes(totals.bytesOut))
          })
          \(downUpLegend())
        </section>
        """

        // Last 30 days
        body += """
        <section class="panel">
          <div class="panel-head">
            <h2>Last 30 days</h2>
            <p class="note">The dashed line is a seven day rolling average of downloads, so one heavy day does not read as a trend.</p>
          </div>
          \(SVGKit.mirroredBars(values: dayValues, labelEvery: 3, rollingAverage: data.rollingAverage) { index in
              let entry = data.daily[index]
              return "\(cal.fullDayLabel(entry.date)), down \(Units.bytes(entry.totals.bytesIn)), up \(Units.bytes(entry.totals.bytesOut))"
          })
          \(downUpLegend(includeAverage: true))
        </section>
        """

        // Heatmap, given the most room because it answers the most useful question
        body += """
        <section class="panel feature">
          <div class="panel-head">
            <h2>When the data actually goes</h2>
            <p class="note">Day of the week against hour of the day, over the last 30 days. Darker is quieter.</p>
          </div>
          <div class="heat-wrap">\(SVGKit.heatmap(cells: data.heat))</div>
          \(SVGKit.heatLegend(peak: heatPeak))
        </section>
        """

        // Top talkers beside the smaller splits
        body += """
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

        if data.monthly.count > 1 {
            let monthValues = data.monthly.map { (label: $0.label, totals: $0.totals) }
            body += """
            <section class="panel">
              <div class="panel-head"><h2>Month by month</h2></div>
              \(SVGKit.mirroredBars(values: monthValues, labelEvery: 1) { index in
                  let entry = data.monthly[index]
                  return "\(entry.label), down \(Units.bytes(entry.totals.bytesIn)), up \(Units.bytes(entry.totals.bytesOut))"
              })
            </section>
            """
        }

        // Footer: how the numbers were made, and what happened
        body += """
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
              <p class="muted">Counter source: \(esc(data.counterSource == "mib64" ? "64 bit interface MIB" : data.counterSource)).</p>
            </div>
            <div>
              <h3>Recent events</h3>
              \(eventList(data))
            </div>
          </div>
          <div class="foot-bar">
            <a class="export" href="bytemeter_export.csv" download>Export CSV</a>
            <span class="muted">Generated by Bytemeter on this Mac. Nothing here has left the machine.</span>
          </div>
        </footer>
        """

        return page(body: body)
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

    private static func miniRow(_ label: String, _ value: UInt64, of total: UInt64) -> String {
        let share = total == 0 ? 0 : Int((Double(value) / Double(total) * 100).rounded())
        return """
        <div><dt>\(esc(label))</dt><dd>\(esc(Units.bytes(value)))<span class="qualifier">\(share)%</span></dd></div>
        """
    }

    private static func downUpLegend(includeAverage: Bool = false) -> String {
        var items = """
        <span class="key"><i class="swatch solid"></i>Down, above the line</span>
        <span class="key"><i class="swatch soft"></i>Up, below the line, on the same scale</span>
        """
        if includeAverage {
            items += "<span class=\"key\"><i class=\"swatch dash\"></i>Seven day average</span>"
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
        return """
        <div class="tables">
          <table><caption>Today</caption>
            <thead><tr><th>Process</th><th class="num">Down</th><th class="num">Up</th><th></th></tr></thead>
            <tbody>\(rows(today))</tbody>
          </table>
          <table><caption>This month</caption>
            <thead><tr><th>Process</th><th class="num">Down</th><th class="num">Up</th><th></th></tr></thead>
            <tbody>\(rows(month))</tbody>
          </table>
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

    private static func networkSection(_ data: DashboardData) -> String {
        guard data.ssidCapture else {
            return """
            <p class="note">Network name capture is off, so everything is recorded against a single placeholder.
            Turning it on in Preferences asks macOS for Location Services, which is what reading a Wi-Fi network
            name needs on this version. While it is off, Bytemeter never touches Location Services at all.</p>
            """
        }
        return breakdownList(data.bySSID)
    }

    private static func capPanel(used: UInt64, cap: UInt64) -> String {
        let fraction = cap == 0 ? 0 : min(1.0, Double(used) / Double(cap))
        return """
        <section class="panel cap">
          <div class="panel-head"><h2>Monthly cap</h2>
            <p class="note">\(esc(Units.bytes(used))) of \(esc(Units.bytes(cap))) used.</p></div>
          <div class="capbar"><span style="width:\(String(format: "%.1f", fraction * 100))%"></span></div>
        </section>
        """
    }

    private static func eventList(_ data: DashboardData) -> String {
        guard !data.events.isEmpty else { return "<p class=\"note\">Nothing to report.</p>" }
        return "<ul class=\"events\">" + data.events.map { event in
            let when = data.cal.timestampLabel(Date(timeIntervalSince1970: TimeInterval(event.ts)))
            return "<li><span class=\"when\">\(esc(when))</span><span class=\"kind\">\(esc(event.kind))</span>"
                 + "<span class=\"detail\">\(esc(event.detail))</span></li>"
        }.joined() + "</ul>"
    }

    private static func comparisonText(today: Totals, yesterday: Totals) -> String {
        guard yesterday.bytesIn > 0 else { return "No figure for yesterday to compare against yet." }
        let change = Double(today.bytesIn) / Double(yesterday.bytesIn)
        let yesterdayText = Units.bytes(yesterday.bytesIn)
        if change >= 1.05 {
            return "Up on yesterday, which came to \(yesterdayText)."
        } else if change <= 0.95 {
            return "Down on yesterday, which came to \(yesterdayText)."
        }
        return "About the same as yesterday, which came to \(yesterdayText)."
    }

    private static func peakHourNote(_ data: DashboardData) -> String {
        guard let peak = data.peakHour else { return "Nothing recorded yet today." }
        return String(format: "Busiest hour so far: %02d:00 to %02d:00, %@ down.",
                      peak.hour, (peak.hour + 1) % 24, Units.bytes(peak.totals.bytesIn))
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
        func add(_ scope: String, _ label: String, _ totals: Totals) {
            let safe = label.replacingOccurrences(of: "\"", with: "'")
            lines.append("\(scope),\"\(safe)\",\(totals.bytesIn),\(totals.bytesOut),"
                       + String(format: "%.6f", Units.gigabytes(totals.total)))
        }
        for (index, totals) in data.hourly.enumerated() {
            add("hour_today", String(format: "%02d:00", index), totals)
        }
        for entry in data.daily { add("day", data.cal.fullDayLabel(entry.date), entry.totals) }
        for entry in data.monthly { add("month", entry.label, entry.totals) }
        for talker in data.topTalkersToday { add("process_today", talker.name, talker.totals) }
        for talker in data.topTalkersMonth { add("process_month", talker.name, talker.totals) }
        for entry in data.byInterface { add("interface_30d", entry.0, entry.1) }
        for entry in data.bySSID { add("network_30d", entry.0, entry.1) }
        add("idle_30d", "Idle", data.idleTotals)
        add("idle_30d", "Active", data.activeTotals)
        return lines.joined(separator: "\n") + "\n"
    }
}
