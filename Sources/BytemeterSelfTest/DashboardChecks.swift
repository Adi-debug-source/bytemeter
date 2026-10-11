import Foundation
import BytemeterCore
import BytemeterDashboard

// Checks on the dashboard page and its CSV export, read as text, the way a
// browser and a spreadsheet get them. The charts and the stylesheet are
// internal to BytemeterDashboard, so nothing here reaches into how the page is
// built: each check makes a page from a small synthetic database and reads
// what came out. This is where the README's promise that the page fetches
// nothing is held, and where the dashboard's own fixes are proved.

func runDashboardChecks() {
    let fewDays = BuiltPage(fewDaysDatabase(), now: fixtureMoment)
    let fortyDays = BuiltPage(fortyUniformDaysDatabase(), now: fixtureMoment)
    checkPageFetchesNothing(["few days": fewDays, "40 days": fortyDays])
    checkOutsideNamesAreEscaped(fewDays)
    checkCSVLinesHaveFiveFields(["few days": fewDays, "40 days": fortyDays])
    checkWriteMakesBothFiles(fewDays)
    checkThirtyDayAxisReadsQuarters(fewDays)
    checkAverageLineOnlyOverAWholeWeek(fewDays: fewDays, fortyDays: fortyDays)
    checkHeatmapCellsAverageWholeWeeks(fortyDays)
    checkCapPanelSaysWhatIsLeftOrOver()
}

// MARK: - The fixtures

/// A Thursday at noon in London, well clear of a clock change, so every
/// local hour of the last 40 days has exactly one row in the uniform fixture.
private let fixtureMoment = "2026-10-08T12:00"

/// A page and its CSV, made from one database as of one moment. Calendar
/// months and no cap unless a check says otherwise.
private struct BuiltPage {
    let data: DashboardData
    let html: String
    let csv: String

    init(_ db: Database, now: String, cal: BytemeterCalendar = london, capBytes: UInt64 = 0) {
        let options = DashboardData.Options(ssidCapture: false, perAppSampling: true,
                                            capEnabled: capBytes > 0, capBytes: capBytes)
        data = DashboardData(aggregator: Aggregator(db: db, cal: cal), options: options, now: cal.parseLocal(now)!)
        html = DashboardGenerator.html(data)
        csv = DashboardGenerator.csvExport(data)
    }

    /// The CSV's lines, each read back as a spreadsheet would read it.
    var csvRows: [[String]] {
        csv.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map { readCSVLine(String($0)) }
    }
}

/// Four days of traffic before the fixture moment, which is under seven whole
/// counted days. The heaviest is 2.2 GB down, so the 30 day chart's axis tops
/// out at 2.5 GB. A night's sleep is spread across the gap, which writes a
/// gap event, and two processes have names a page or a spreadsheet could take
/// for markup or a formula.
private func fewDaysDatabase() -> Database {
    let db = makeDatabase()
    func at(_ local: String, _ bytesIn: UInt64, _ bytesOut: UInt64) {
        db.addBuckets([BucketDelta(minute: BytemeterCalendar.minute(from: london.parseLocal(local)!),
                                   iface: "en0", bytesIn: bytesIn, bytesOut: bytesOut)],
                      ssid: ssidPlaceholder, idle: false)
    }
    at("2026-10-05T09:00", 300_000_000, 30_000_000)
    at("2026-10-06T10:00", 2_200_000_000, 100_000_000)
    at("2026-10-07T09:00", 400_000_000, 40_000_000)
    at("2026-10-08T10:00", 100_000_000, 10_000_000)

    // Asleep from 23:00 to 07:00, then the first reading after waking.
    let slept = Int64(london.parseLocal("2026-10-07T23:00")!.timeIntervalSince1970)
    let woke = Int64(london.parseLocal("2026-10-08T07:00")!.timeIntervalSince1970)
    db.saveBaselines(["en0": RawCounter(bytesIn: 1_000_000, bytesOut: 100_000, at: slept, bootSession: "A", source: .mib64)])
    let wake = Ledger.ingest(readings: [reading("en0", 1_000_000 + 480_000_000, 100_000 + 48_000_000)],
                             previous: db.baselines(), now: woke, reason: .sleep, bootTime: nil, bootSession: "A")
    _ = db.transaction { try db.writeReading(wake, ssid: ssidPlaceholder, idle: false, reason: .sleep, counterSource: .mib64) }

    db.addProcBuckets(minute: BytemeterCalendar.minute(from: london.parseLocal("2026-10-08T10:00")!),
                      deltas: ["=HYPERLINK(\"x\")": (50_000_000, 5_000_000), "<b>bold</b>": (20_000_000, 2_000_000)])
    return db
}

/// 60 MB down and 6 MB up at the start of every hour for the 40 days before
/// the fixture moment.
private func fortyUniformDaysDatabase() -> Database {
    let db = makeDatabase()
    let end = BytemeterCalendar.minute(from: london.parseLocal(fixtureMoment)!)
    let rows = stride(from: end - 40 * 24 * 60, to: end, by: 60).map {
        BucketDelta(minute: $0, iface: "en0", bytesIn: 60_000_000, bytesOut: 6_000_000)
    }
    _ = db.transaction { db.addBuckets(rows, ssid: ssidPlaceholder, idle: false) }
    return db
}

/// The part of a page from a panel's heading to the end of its section, so a
/// check on one chart cannot pass on a figure another chart printed.
private func panel(_ page: String, heading: String) -> String {
    guard let start = page.range(of: "<h2>\(heading)</h2>"),
          let end = page.range(of: "</section>", range: start.upperBound..<page.endIndex) else { return "" }
    return String(page[start.lowerBound..<end.upperBound])
}

// MARK: - The page fetches nothing

private func checkPageFetchesNothing(_ pages: [String: BuiltPage]) {
    for (name, built) in pages.sorted(by: { $0.key < $1.key }) {
        let text = built.html.lowercased()
        for banned in ["<script", "http:", "https:", "<link", "@import"] {
            check(!text.contains(banned), "the \(name) page holds no \(banned), in any case")
        }
        let urls = text.components(separatedBy: "url(").dropFirst()
        check(!urls.isEmpty && urls.allSatisfy { $0.hasPrefix("data:") || $0.hasPrefix("#") },
              "every url( on the \(name) page is a data: URL or a fragment on the page")
    }
    // The fonts give data: URLs; the sleep's hatched hours give fragments.
    check(pages["few days"].map { $0.html.contains("url(data:") && $0.html.contains("url(#") } ?? false,
          "the few days page has both kinds of url(, so the rule above is tried on each")
}

// MARK: - Names from outside are text, on the page and in the CSV

private func checkOutsideNamesAreEscaped(_ built: BuiltPage) {
    check(built.html.contains("&lt;b&gt;bold&lt;/b&gt;"), "a process name is escaped on the page")
    check(!built.html.contains("<b>bold</b>"), "so it never reaches the page as markup")
    check(built.html.contains("=HYPERLINK(&quot;x&quot;)"), "and its quotes are escaped too")
    let names = built.csvRows.filter { $0.first == "process_today" }.map { $0.count > 1 ? $0[1] : "" }
    expect(names, ["'=HYPERLINK(\"x\")", "<b>bold</b>"],
           "in the CSV a formula name reads back with a leading apostrophe, and markup reads back as it is")
    check(built.html.contains("<ul class=\"events\">"), "the sleep's event is listed under Recent events")
}

// MARK: - The CSV has one shape of line

private func checkCSVLinesHaveFiveFields(_ pages: [String: BuiltPage]) {
    for (name, built) in pages.sorted(by: { $0.key < $1.key }) {
        let rows = built.csvRows
        check(built.csv.hasSuffix("\n") && rows.count > 1, "the \(name) CSV has rows and ends with a line break")
        expect(rows.first, ["scope", "label", "bytes_in", "bytes_out", "total_gb"], "the \(name) CSV's header")
        expect(Set(rows.map(\.count)), [5], "every line of the \(name) CSV has exactly five fields")
    }
}

// MARK: - Writing puts both files in the folder

private func checkWriteMakesBothFiles(_ built: BuiltPage) {
    let folder = URL(fileURLWithPath: scratchFolder + "dashboard-\(UUID().uuidString)", isDirectory: true)
    let written = try? DashboardGenerator.write(data: built.data, folder: folder)
    expect(written, folder.appendingPathComponent(DashboardGenerator.pageFile), "write makes the folder and returns the page")
    let page = try? String(contentsOf: folder.appendingPathComponent(DashboardGenerator.pageFile), encoding: .utf8)
    let csv = try? String(contentsOf: folder.appendingPathComponent(DashboardGenerator.csvFile), encoding: .utf8)
    check(page == built.html, "the page written is the page built")
    check(csv == built.csv, "and the CSV is written beside it")
    check(built.html.contains("href=\"\(DashboardGenerator.csvFile)\""), "the page's export link names the CSV beside it")
}

// MARK: - The 30 day chart's axis

private func checkThirtyDayAxisReadsQuarters(_ built: BuiltPage) {
    let chart = panel(built.html, heading: "Last 30 days")
    check(chart.contains("class=\"axis\">2.5 GB<"), "a 2.2 GB day puts the 30 day chart's top line at 2.5 GB")
    check(chart.contains("class=\"axis\">1.25 GB<"), "and its middle line reads 1.25 GB, where one decimal said 1.3 GB")
}

// MARK: - The seven day average needs a whole week

private func checkAverageLineOnlyOverAWholeWeek(fewDays: BuiltPage, fortyDays: BuiltPage) {
    check(!fewDays.html.contains("Seven day average"), "under seven whole counted days, the key has no seven day average")
    check(!fewDays.html.contains("<polyline"), "and the chart draws no line")
    check(fortyDays.html.contains("Seven day average"), "with 40 days counted, the key names the seven day average")
    check(fortyDays.html.contains("<polyline"), "and the chart draws it")
    // 30 days a chart, a point once seven whole days are in, none for today.
    let points = fortyDays.html.components(separatedBy: "<polyline points=\"").dropFirst().first?
        .components(separatedBy: "\"").first?.split(separator: " ") ?? []
    expect(points.count, 23, "the line starts on the seventh day and stops at yesterday")
    expect(Set(points.map { $0.split(separator: ",").last ?? "" }).count, 1, "and on steady traffic it is flat")
}

// MARK: - The heatmap is an average over whole weeks

private func checkHeatmapCellsAverageWholeWeeks(_ built: BuiltPage) {
    let tooltips = built.html.components(separatedBy: "<g class=\"cell\"><title>").dropFirst()
        .map { $0.components(separatedBy: "</title>")[0] }
    expect(tooltips.count, 168, "the heatmap has a cell for every hour of the week")
    let figures = Set(tooltips.map { tip in tip.range(of: "on average down").map { String(tip[$0.lowerBound...]) } ?? tip })
    expect(figures, ["on average down 60.0 MB, up 6.0 MB, over 4 weeks."],
           "on 40 uniform days every heatmap cell carries the same average, over four whole weeks")
}

// MARK: - The cap panel says what is left or over

private func checkCapPanelSaysWhatIsLeftOrOver() {
    /// The cap panel's note and bar, as the page has them.
    func capPanel(_ built: BuiltPage) -> (note: String, width: String) {
        let section = panel(built.html, heading: "Monthly cap")
        let note = section.components(separatedBy: "<p class=\"note\">").dropFirst().first?
            .components(separatedBy: "</p>").first ?? ""
        let width = section.components(separatedBy: "<span style=\"width:").dropFirst().first?
            .components(separatedBy: "\"").first ?? ""
        return (note, width)
    }
    check(!BuiltPage(fortyUniformDaysDatabase(), now: fixtureMoment).html.contains("Monthly cap"),
          "with no cap set, the page has no cap panel")

    // 66 MB an hour from 00:00 on 15 September to 12:00 on 8 October is
    // 37.224 GB, down and up together. The cycle's last day is 14 October.
    let cycle15 = BytemeterCalendar(timeZone: london.calendar.timeZone, cycleStartDay: 15)
    let under = capPanel(BuiltPage(fortyUniformDaysDatabase(), now: fixtureMoment, cal: cycle15, capBytes: 40_000_000_000))
    expect(under.note, "37.2 GB of 40.0 GB used, 93%. 2.78 GB left, 7 days to go.",
           "the cap panel gives what is used, the percentage, and what is left for how long")
    expect(under.width, "93%", "and its bar is filled to the percentage")

    // Calendar months: 1 October to 8 October at noon is 11.88 GB.
    let over = capPanel(BuiltPage(fortyUniformDaysDatabase(), now: fixtureMoment, capBytes: 10_000_000_000))
    expect(over.note, "11.9 GB of 10.0 GB used, 118%. 1.88 GB over the cap.",
           "past the cap, the panel gives the real percentage and how far over")
    expect(over.width, "100%", "while its bar stops at full")
}
