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
    let fortyDaysOnACycle = BuiltPage(fortyUniformDaysDatabase(), now: fixtureMoment, cal: cycleFrom15th)
    checkPageFetchesNothing(["few days": fewDays, "40 days": fortyDays])
    checkOutsideNamesAreEscaped(fewDays)
    checkCSVLinesHaveFiveFields(["few days": fewDays, "40 days": fortyDays])
    checkWriteMakesBothFiles(fewDays)
    checkThirtyDayAxisReadsQuarters(fewDays)
    checkAverageLineOnlyOverAWholeWeek(fewDays: fewDays, fortyDays: fortyDays)
    checkHeatmapCellsAverageWholeWeeks(fortyDays)
    checkCapPanelSaysWhatIsLeftOrOver()
    checkLabelsNameTheirPeriod(months: fortyDays, cycles: fortyDaysOnACycle)
    checkLongHistoriesKeepTheirLabelsApart()
    checkChartsAndNamesCanBeRead(fewDays: fewDays, fortyDays: fortyDays, cycles: fortyDaysOnACycle)
    checkMutedTextMeetsAA(fewDays)
    checkEmptyChartsDrawNoScale(fewDays)
}

// MARK: - The fixtures

/// A Thursday at noon in London, well clear of a clock change, so every
/// local hour of the last 40 days has exactly one row in the uniform fixture.
private let fixtureMoment = "2026-10-08T12:00"

/// A billing cycle from the 15th, in London. As of the fixture moment, the
/// 40 uniform days span the cycles from 15 August and 15 September.
private let cycleFrom15th = BytemeterCalendar(timeZone: london.calendar.timeZone, cycleStartDay: 15)

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
    let under = capPanel(BuiltPage(fortyUniformDaysDatabase(), now: fixtureMoment, cal: cycleFrom15th,
                                   capBytes: 40_000_000_000))
    expect(under.note, "37.2 GB of 40.0 GB used, 93%. 2.78 GB left, 7 days to go.",
           "the cap panel gives what is used, the percentage, and what is left for how long")
    expect(under.width, "93%", "and its bar is filled to the percentage")

    // Calendar months: 1 October to 8 October at noon is 11.88 GB.
    let over = capPanel(BuiltPage(fortyUniformDaysDatabase(), now: fixtureMoment, capBytes: 10_000_000_000))
    expect(over.note, "11.9 GB of 10.0 GB used, 118%. 1.88 GB over the cap.",
           "past the cap, the panel gives the real percentage and how far over")
    expect(over.width, "100%", "while its bar stops at full")
}

// MARK: - Labels say which period they cover

private func checkLabelsNameTheirPeriod(months: BuiltPage, cycles: BuiltPage) {
    func monthRows(_ built: BuiltPage) -> [String] {
        built.csvRows.filter { $0.first == "month" }.map { $0.count > 1 ? $0[1] : "" }
    }
    let note = "Each bar is a billing cycle, starting on the day shown."

    check(months.html.contains("<caption>This month</caption>") && !months.html.contains("<caption>This cycle"),
          "on calendar months, the second Top talkers table is this month")
    check(!months.html.contains(note), "and Month by month has no billing cycle note")
    expect(monthRows(months), ["Aug 2026", "Sep 2026", "Oct 2026"], "and the CSV's month rows are named by month")

    check(cycles.html.contains("<caption>This cycle</caption>") && !cycles.html.contains("<caption>This month"),
          "on a billing cycle from the 15th, the second Top talkers table is this cycle")
    check(panel(cycles.html, heading: "Month by month").contains("<p class=\"note\">\(note)</p>"),
          "and Month by month says each bar is a billing cycle")
    expect(monthRows(cycles), ["15 Aug 2026", "15 Sep 2026"],
           "and the CSV's month rows are named by the day each cycle starts, under the same scope")
    check(cycles.html.contains(">15 Sep 2026</text>"), "as are the bars")

    for (name, built) in [("calendar months", months), ("a billing cycle", cycles)] {
        check(built.html.contains("<h2>Per interface, last 30 days</h2>") && built.html.contains("<h2>Per network, last 30 days</h2>"),
              "on \(name), the interface and network headings say they cover the last 30 days")
        check(built.html.contains("Idle means no keyboard, mouse or trackpad input for five minutes or more, over the last 30 days."),
              "on \(name), the idle note names every kind of input that counts")
    }
}

// MARK: - A long Month by month keeps its labels apart

private func checkLongHistoriesKeepTheirLabelsApart() {
    /// Month by month's bars, and the labels drawn under them, in order.
    func monthly(since local: String, cal: BytemeterCalendar) -> (bars: Int, labels: [String]) {
        let db = makeDatabase()
        db.addBuckets([BucketDelta(minute: BytemeterCalendar.minute(from: london.parseLocal(local)!), iface: "en0",
                                   bytesIn: 1_000_000, bytesOut: 100_000)], ssid: ssidPlaceholder, idle: false)
        let section = panel(BuiltPage(db, now: fixtureMoment, cal: cal).html, heading: "Month by month")
        let labels = section.components(separatedBy: "text-anchor=\"middle\" class=\"axis\">").dropFirst()
            .map { $0.components(separatedBy: "<").first ?? "" }
        return (section.components(separatedBy: "<g class=\"bar\">").count - 1, labels)
    }

    let year = monthly(since: "2025-10-20T10:00", cal: cycleFrom15th)
    expect(year.bars, 12, "twelve billing cycles from 15 October 2025 draw twelve bars")
    expect(year.labels.count, 12, "and each has its label, since twelve fit")

    let longer = monthly(since: "2025-08-20T10:00", cal: cycleFrom15th)
    expect(longer.bars, 14, "fourteen billing cycles draw fourteen bars")
    expect(longer.labels, ["15 Aug 2025", "15 Oct 2025", "15 Dec 2025", "15 Feb 2026", "15 Apr 2026", "15 Jun 2026", "15 Aug 2026"],
           "and label every second one, oldest first, rather than run fourteen dates into each other")

    let months = monthly(since: "2025-08-20T10:00", cal: london)
    expect(months.bars, 15, "the same history in calendar months draws fifteen bars")
    expect(months.labels.count, 15, "and labels every one, since the month names are shorter")
}

// MARK: - A screen reader can tell what each chart shows, and a cut-short name can be read whole

private func checkChartsAndNamesCanBeRead(fewDays: BuiltPage, fortyDays: BuiltPage, cycles: BuiltPage) {
    /// The aria-label of each chart, in page order, or "" for one without.
    func chartLabels(_ html: String) -> [String] {
        html.components(separatedBy: "role=\"img\"").dropFirst().map { rest in
            let tag = rest.components(separatedBy: ">").first ?? ""
            guard tag.hasPrefix(" aria-label=\"") else { return "" }
            return tag.dropFirst(" aria-label=\"".count).components(separatedBy: "\"").first ?? ""
        }
    }
    func count(_ text: String, in html: String) -> Int { html.components(separatedBy: text).count - 1 }

    // Hourly, daily, the heatmap and the idle split, and Month by month once
    // a second month has begun.
    for (name, built, charts) in [("few days", fewDays, 4), ("40 days", fortyDays, 5), ("billing cycle", cycles, 5)] {
        let labels = chartLabels(built.html)
        expect(labels.count, charts, "the \(name) page draws \(charts) charts, each a role=\"img\"")
        check(!labels.contains(""), "every chart on the \(name) page has an aria-label")
        expect(count("aria-label=", in: built.html), count("<svg ", in: built.html),
               "the \(name) page has one aria-label for each chart drawn, and none elsewhere")
        let names = count("<td class=\"name\"", in: built.html)
        check(names > 0 || name != "few days", "the few days page lists processes")
        expect(count("<td class=\"name\" title=\"", in: built.html), names,
               "every process name on the \(name) page carries its whole name as a title")
    }
    check(fewDays.html.contains("<td class=\"name\" title=\"&lt;b&gt;bold&lt;/b&gt;\">"), "and the title is escaped")

    // 66 MB an hour, all active, from 00:00 on 9 September to noon on 8 October: 46.728 GB.
    let heatmap = "Average download and upload by day of the week and hour of the day, over the last four whole weeks."
    expect(chartLabels(fortyDays.html), [
        "Download and upload for each hour of today.",
        "Download and upload for each of the last 30 days, with a seven day average.",
        heatmap,
        "Active 46.7 GB and idle 0 B, over the last 30 days.",
        "Download and upload for each month.",
    ], "on 40 days each chart says what it shows, and the idle split gives both figures")
    expect(chartLabels(cycles.html).last, "Download and upload for each billing cycle.",
           "on a billing cycle Month by month says each bar is a cycle")
    expect(chartLabels(fewDays.html).dropFirst().first, "Download and upload for each of the last 30 days.",
           "with no seven day average drawn, the 30 day chart does not name one")
    expect(chartLabels(fewDays.html).last, "Active 3.18 GB and idle 528 MB, over the last 30 days.",
           "the idle split names both its figures, the sleep's spread traffic as idle")
}

// MARK: - Muted text is readable on the page

/// The WCAG 2 contrast ratio of two #rrggbb colours.
private func contrast(_ first: String, _ second: String) -> Double {
    func luminance(_ hex: String) -> Double {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        let channels = [value >> 16, value >> 8 & 0xff, value & 0xff].map { channel -> Double in
            let c = Double(channel) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
    let (a, b) = (luminance(first), luminance(second))
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

private func checkMutedTextMeetsAA(_ built: BuiltPage) {
    /// A colour the stylesheet sets in :root, such as --muted.
    func colour(_ name: String) -> String {
        String(built.html.components(separatedBy: "\(name): ").dropFirst().first?.prefix(7) ?? "")
    }
    let muted = colour("--muted"), plane = colour("--plane")
    check(contrast(muted, plane) >= 4.5,
          "notes, axis labels and table headings in \(muted) on \(plane) clear WCAG AA's 4.5 to 1, at \(contrast(muted, plane))")
    check(contrast("#6d777e", "#0b0d0f") < 4.5, "where the earlier grey, at 4.26 to 1, did not")
}

// MARK: - A chart with nothing on it draws its baseline and no scale

private func checkEmptyChartsDrawNoScale(_ fewDays: BuiltPage) {
    /// Every axis figure in a piece of the page, in order.
    func axisFigures(_ html: String) -> [String] {
        html.components(separatedBy: "class=\"axis\">").dropFirst().map { $0.components(separatedBy: "<")[0] }
    }
    func count(_ text: String, in html: String) -> Int { html.components(separatedBy: text).count - 1 }

    // A new install: nothing counted at all.
    let empty = BuiltPage(makeDatabase(), now: fixtureMoment)
    let byteFigures = axisFigures(empty.html).filter { $0.hasSuffix("B") }
    check(byteFigures.isEmpty, "an empty page has no axis figure in bytes, where it had 0 B and 1 B, got \(byteFigures)")
    expect(count("role=\"img\"", in: empty.html), 4, "and still draws its four charts")
    for heading in ["Today by hour", "Last 30 days"] {
        let chart = panel(empty.html, heading: heading)
        check(count("<line ", in: chart) == 1 && count("<g class=\"bar\">", in: chart) > 0,
              "the empty \(heading) chart draws its baseline alone, and keeps a column for each bar")
        check(!chart.contains("class=\"axis\">0<"), "and no 0 beside it, with no scale to start")
    }

    // Just after midnight today's chart has nothing on it, while the 30 days do.
    let midnight = BuiltPage(fewDaysDatabase(), now: "2026-10-09T00:30")
    check(axisFigures(panel(midnight.html, heading: "Today by hour")).allSatisfy { !$0.hasSuffix("B") && $0 != "0" },
          "just after midnight, today's empty chart draws no scale")
    check(panel(midnight.html, heading: "Last 30 days").contains("class=\"axis\">2.5 GB<"),
          "while the 30 day chart beside it keeps its own")
    let hourly = panel(fewDays.html, heading: "Today by hour")
    check(axisFigures(hourly).filter { $0.hasSuffix("B") }.count == 4 && hourly.contains("class=\"axis\">0<"),
          "a chart with traffic keeps the figures on its gridlines, and its 0")
}

