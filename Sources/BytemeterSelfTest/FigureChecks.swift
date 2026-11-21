import Foundation
import BytemeterCore

// Checks for the figures the menu and the dashboard show: the units, top
// talkers, the menu bar modes, averages, the projection, the heatmap, the
// seven-day average, the comparison with yesterday, month by month, all
// time, the figures as of a moment, the headline set, the menu's four
// periods and its app names, the cap, and the menu's line while counting has
// only just started.

// MARK: - Units are decimal

func checkUnitsAreDecimal() {
    expect(Units.bytes(999), "999 B", "bytes under a kB")
    expect(Units.bytes(1_000_000), "1.0 MB", "one MB is a million bytes")
    expect(Units.bytes(1_000_000_000), "1.00 GB", "one GB is a thousand million bytes")
    expect(Units.bytes(4_800_000_000), "4.80 GB", "GB with two decimals")
    expect(Units.bytes(4_800_000_000, compact: true), "4.8 GB", "compact GB for the menu bar")
    expect(Units.rate(2_100_000), "2.1 MB/s", "rate formatting")
}

// MARK: - Figures never print as 1000 of a smaller unit

func checkNoFigureReadsAsAThousand() {
    // Each of these rounds up to the next threshold, where the larger
    // figure's rule must take over.
    let cases: [(String, String, String)] = [
        (Units.bytes(999_499), "999 kB", "just under 1 MB stays in kB"),
        (Units.bytes(999_600), "1.0 MB", "999.6 kB rounds to 1.0 MB, not 1000 kB"),
        (Units.bytes(9_960), "10 kB", "9.96 kB drops its decimal at 10 kB"),
        (Units.bytes(99_960_000), "100 MB", "99.96 MB drops its decimal at 100 MB"),
        (Units.bytes(999_600_000), "1.00 GB", "999.6 MB rounds to 1.00 GB, not 1000 MB"),
        (Units.bytes(9_996_000_000), "10.0 GB", "9.996 GB keeps one decimal at 10 GB"),
        (Units.bytes(999_600, compact: true), "1 MB", "the menu bar's 999.6 kB is 1 MB"),
        (Units.bytes(999_600_000, compact: true), "1.0 GB", "the menu bar's 999.6 MB is 1.0 GB"),
        (Units.rate(999.6), "1 kB/s", "a rate of 999.6 B/s is 1 kB/s"),
        (Units.rate(999_600), "1.0 MB/s", "a rate of 999.6 kB/s is 1.0 MB/s"),
        (Units.rate(999_960_000), "1.00 GB/s", "a rate of 999.96 MB/s is 1.00 GB/s"),
    ]
    for (actual, expected, message) in cases {
        expect(actual, expected, message)
    }
}

// MARK: - Top talkers rank by total bytes

func checkTopTalkersRankByTotal() {
    let db = makeDatabase()
    db.addProcBuckets(minute: 50, deltas: ["Safari": (5_000, 100), "Backup": (9_000, 50)])
    let talkers = Aggregator(db: db, cal: london).topTalkers(MinuteRange(start: 0, end: 100), limit: 5)
    expect(talkers.first?.name, "Backup", "top talkers rank by total bytes")
    expect(talkers.count, 2, "both processes are listed")
}

// MARK: - Menu bar mode cycling

func checkStatusModesCycle() {
    expect(StatusMode.today.next, StatusMode.last7, "clicking today gives the last 7 days")
    expect(StatusMode.last7.next, StatusMode.last30, "clicking the last 7 days gives the last 30 days")
    expect(StatusMode.last30.next, StatusMode.allTime, "clicking the last 30 days gives all time")
    expect(StatusMode.allTime.next, StatusMode.today, "clicking all time comes back to today")
    expect(StatusMode.allCases.count, 4, "four positions in the cycle")
    expect(StatusMode(saved: StatusMode.last30.rawValue), StatusMode.last30, "the saved mode round trips")
    // Up to 1.3.1 the cycle held this week and this month. A saved one must
    // not fall back to today on upgrade, but to the rolling period nearest it.
    expect(StatusMode(saved: "week"), StatusMode.last7, "a saved this week comes back as the last 7 days")
    expect(StatusMode(saved: "month"), StatusMode.last30, "a saved this month comes back as the last 30 days")
    expect(StatusMode(saved: StatusMode.allTime.rawValue), StatusMode.allTime, "all time round trips through settings")
    expect(StatusMode(saved: "fortnight"), StatusMode.today, "an unknown saved mode falls back to today")
    expect(StatusMode(saved: nil), StatusMode.today, "no saved mode means today")
    expect(StatusMode.today.label, "Today", "labels are the ones shown in the menu")
    expect(StatusMode.allTime.label, "All time", "the all time label is short, with no date, for the menu bar")
}

// MARK: - The shaped views carry the estimated share

func checkShapedViewsCarryTheEstimate() {
    let db = makeDatabase()
    var components = DateComponents()
    components.year = 2026; components.month = 10; components.day = 1; components.hour = 3
    let threeAM = london.calendar.date(from: components)!
    let minute = BytemeterCalendar.minute(from: threeAM)
    db.addBuckets([BucketDelta(minute: minute, iface: "en0", bytesIn: 900, bytesOut: 90, estimated: true),
                   BucketDelta(minute: minute + 1, iface: "en0", bytesIn: 100, bytesOut: 10)],
                  ssid: ssidPlaceholder, idle: true)
    let aggregator = Aggregator(db: db, cal: london)
    let hour = aggregator.hourly(day: threeAM, now: threeAM.addingTimeInterval(3_600))[3]
    expect(hour.bytesIn, 1_000, "the hour's total counts both minutes")
    expect(hour.estimatedIn, 900, "the hour knows which part was spread")
    let day = aggregator.daily(lastDays: 1, now: threeAM.addingTimeInterval(3_600)).last?.totals
    expect(day?.estimatedOut, 90, "the day knows which part was spread")
    // The heatmap counts only whole days from when counting began, and
    // leaves today out, so the day needs a row at its start and is asked
    // about the morning after.
    db.addBuckets([BucketDelta(minute: BytemeterCalendar.minute(from: london.startOfDay(threeAM)), iface: "en0",
                               bytesIn: 0, bytesOut: 0)], ssid: ssidPlaceholder, idle: true)
    let heat = aggregator.heatmap(weeks: 1, now: threeAM.addingTimeInterval(86_400 + 3_600))
    expect(heat.map(\.totals.estimatedIn).reduce(0, +), 900, "the heatmap knows which part was spread")
}

// MARK: - Month by month keeps the newest months, whatever stray row sits years back

func checkMonthByMonthKeepsTheNewestMonths() {
    let now = london.parseLocal("2026-10-02T12:00")!
    let stray = makeDatabase()
    stray.addBuckets([BucketDelta(minute: londonMinute("2001-01-01T10:00"), iface: "en0",
                                  bytesIn: 5, bytesOut: 0),
                      BucketDelta(minute: londonMinute("2026-03-15T10:00"), iface: "en0",
                                  bytesIn: 1_000, bytesOut: 0),
                      BucketDelta(minute: BytemeterCalendar.minute(from: now) - 10, iface: "en0", bytesIn: 7_000_000_000, bytesOut: 0)],
                     ssid: ssidPlaceholder, idle: false)
    let rows = Aggregator(db: stray, cal: london).monthly(now: now)
    expect(rows.last?.label, "Oct 2026", "month by month always ends with the current month")
    expect(rows.first?.label, "Mar 2026", "and starts at the first month with data in the decade it can show")
    expect(rows.count, 8, "March to October")
    let long = makeDatabase()
    for month in 0..<202 {     // every month from January 2010 to October 2026
        let date = london.calendar.date(byAdding: .month, value: month, to: london.parseLocal("2010-01-15T12:00")!)!
        long.addBuckets([BucketDelta(minute: BytemeterCalendar.minute(from: date), iface: "en0", bytesIn: 1, bytesOut: 0)],
                        ssid: ssidPlaceholder, idle: false)
    }
    let longRows = Aggregator(db: long, cal: london).monthly(now: now)
    check(longRows.count == Aggregator.maxMonths && longRows.first?.label == "Nov 2016" && longRows.last?.label == "Oct 2026",
          "a longer history keeps the newest \(Aggregator.maxMonths) months, got \(longRows.count) from \(longRows.first?.label ?? "") to \(longRows.last?.label ?? "")")
}

// MARK: - Month by month names a billing cycle by its first day

func checkMonthByMonthNamesItsPeriods() {
    let db = makeDatabase()
    for (local, bytes) in [("2026-08-20T10:00", 1_000), ("2026-09-10T10:00", 2_000),
                           ("2026-09-20T10:00", 30_000), ("2026-10-02T10:00", 400_000)] as [(String, UInt64)] {
        db.addBuckets([BucketDelta(minute: londonMinute(local), iface: "en0",
                                   bytesIn: bytes, bytesOut: 0)], ssid: ssidPlaceholder, idle: false)
    }
    let now = london.parseLocal("2026-10-08T12:00")!
    let months = Aggregator(db: db, cal: london).monthly(now: now)
    expect(months.map(\.label), ["Aug 2026", "Sep 2026", "Oct 2026"], "calendar months are named by month")
    expect(months.map(\.totals.bytesIn), [1_000, 32_000, 400_000], "and hold their own months")
    let cycle15 = BytemeterCalendar(timeZone: london.calendar.timeZone, cycleStartDay: 15)
    let cycles = Aggregator(db: db, cal: cycle15).monthly(now: now)
    expect(cycles.map(\.label), ["15 Aug 2026", "15 Sep 2026"], "a billing cycle from the 15th is named by its first day")
    expect(cycles.map(\.totals.bytesIn), [3_000, 430_000], "and holds the 15th to the 14th")
}

// MARK: - Averages and the projection count from when counting began

func checkAveragesCountFromWhenCountingBegan() {
    let megabyte: UInt64 = 1_000_000
    /// 1 MB in every minute from `began` up to `now`: 60 MB an hour, 1.44 GB a day.
    func steady(_ began: String, _ now: String) -> (Aggregator, Date) {
        let db = makeDatabase()
        let end = london.parseLocal(now)!
        var rows: [BucketDelta] = []
        var minute = londonMinute(began)
        while minute < BytemeterCalendar.minute(from: end) {
            rows.append(BucketDelta(minute: minute, iface: "en0", bytesIn: megabyte, bytesOut: 0))
            minute += 1
        }
        db.addBuckets(rows, ssid: ssidPlaceholder, idle: false)
        return (Aggregator(db: db, cal: london), end)
    }
    func near(_ actual: UInt64, _ expected: Double, _ message: String) {
        check(abs(Double(actual) - expected) <= expected * 0.005, "\(message): expected about \(UInt64(expected)), got \(actual)")
    }

    // The start of a month: counting began at 10:00 on 28 August, asked at 12:00 on the 29th.
    let (month, monthNow) = steady("2026-08-28T10:00", "2026-08-29T12:00")
    let began = london.parseLocal("2026-08-28T10:00")!
    near(month.averagePerDay(london.thisCycle(monthNow), now: monthNow).bytesIn, 1_440 * Double(megabyte),
         "per day this month counts the days since counting began")
    near(month.averagePerDay(london.thisCycle(monthNow), now: monthNow).bytesIn, Double(month.allTime(now: monthNow).perDay.bytesIn),
         "so in the first month it agrees with per day, all time")
    let soFar = Double(month.totals(london.thisCycle(monthNow)).bytesIn)
    let runway = london.endOfCycle(monthNow).timeIntervalSince(began) / monthNow.timeIntervalSince(began)
    near(month.projection(now: monthNow)?.bytesIn ?? 0, soFar * runway,
         "the projection runs the rate since counting began to the end of the month")

    // The start of a week: counting began at 09:00 on Wednesday 30 September, asked at 21:00 on Friday 2 October.
    let (week, weekNow) = steady("2026-09-30T09:00", "2026-10-02T21:00")
    near(week.averagePerDay(london.thisWeek(weekNow), now: weekNow).bytesIn, 1_440 * Double(megabyte),
         "per day this week counts the days since counting began, not since Monday")
    near(week.averagePerDay(london.thisCycle(weekNow), now: weekNow).bytesIn, 1_440 * Double(megabyte),
         "per day this month still counts from the 1st when counting began in September")
    near(week.averagePerHourToday(now: weekNow).bytesIn, 60 * Double(megabyte),
         "per hour today counts from midnight when counting began before today")

    // The start of a day: counting began at 14:00, asked at 16:00.
    let (day, dayNow) = steady("2026-10-02T14:00", "2026-10-02T16:00")
    near(day.averagePerHourToday(now: dayNow).bytesIn, 60 * Double(megabyte),
         "per hour today counts the hours since counting began, not since midnight")

    // The menu and the dashboard word the same projection.
    let snapshot = MenuSnapshot(aggregator: month, now: monthNow)
    expect(snapshot.projection, ProjectionWording(projected: month.projection(now: monthNow), now: monthNow, cal: london),
           "the menu's projection is worded from the same figure the dashboard uses")
}

// MARK: - The projection on a cycle's first day, and too early to say

/// `down` and `up` bytes in every minute from `from` up to, not including,
/// `to`, both local times in `cal`, written in one transaction.
private func steadyTraffic(from: String, to: String, down: UInt64, up: UInt64 = 0,
                           cal: BytemeterCalendar = london) -> Database {
    let db = makeDatabase()
    let end = BytemeterCalendar.minute(from: cal.parseLocal(to)!)
    var rows: [BucketDelta] = []
    var minute = BytemeterCalendar.minute(from: cal.parseLocal(from)!)
    while minute < end {
        rows.append(BucketDelta(minute: minute, iface: "en0", bytesIn: down, bytesOut: up))
        minute += 1
    }
    _ = db.transaction { db.addBuckets(rows, ssid: ssidPlaceholder, idle: false) }
    return db
}

func checkProjectionOnACyclesFirstDay() {
    // 1 MB down in every minute since 1 September, so a right projection is
    // 1 MB for every minute of the cycle. Scaling the first hours of a month
    // up as if they were a whole day read a quarter of that at 06:00.
    let db = steadyTraffic(from: "2026-09-01T00:00", to: "2026-10-16T00:00", down: 1_000_000)
    func cycleMB(_ cal: BytemeterCalendar, _ now: Date) -> Double {
        cal.endOfCycle(now).timeIntervalSince(cal.startOfCycle(now)) / 60
    }
    func within(_ projected: Totals?, _ expected: Double, _ message: String) {
        let got = Double(projected?.bytesIn ?? 0) / 1_000_000
        check(abs(got - expected) <= expected * 0.005, "\(message): expected about \(Int(expected)) MB, got \(got) MB")
    }
    expect(cycleMB(london, london.parseLocal("2026-10-01T06:00")!), 44_700,
           "October 2026 in London is 44,700 minutes long, because the clocks go back on the 25th")
    let month = Aggregator(db: db, cal: london)
    for at in ["2026-10-01T06:00", "2026-10-01T23:59", "2026-10-02T00:00"] {
        let now = london.parseLocal(at)!
        within(month.projection(now: now), cycleMB(london, now),
               "at \(at) the projection runs the real rate to the end of the month")
    }
    let cycle15 = BytemeterCalendar(timeZone: london.calendar.timeZone, cycleStartDay: 15)
    let cycleNow = cycle15.parseLocal("2026-10-15T06:00")!
    within(Aggregator(db: db, cal: cycle15).projection(now: cycleNow), cycleMB(cycle15, cycleNow),
           "and so it does on the first morning of a billing cycle")

    // A new install with under a day counted has nothing to run on.
    let fresh = steadyTraffic(from: "2026-10-02T10:00", to: "2026-10-02T16:00", down: 1_000_000)
    let freshNow = london.parseLocal("2026-10-02T16:00")!
    let early = Aggregator(db: fresh, cal: london).projection(now: freshNow)
    check(early == nil, "six hours after counting began, it is too early to project")
    let wording = ProjectionWording(projected: early, now: freshNow, cal: london)
    check(wording.isTooEarly, "the wording knows it is too early")
    expect(wording.figure, "Too early", "the tile's figure says too early")
    expect(wording.headline, "Too early to project October", "the menu's line names the month in full")
    expect(wording.deadline, "by the end of October", "the deadline is still worked out")
    expect(wording.title, "Projection", "the tile is headed Projection, not On track for")
    expect(wording.qualifier, "to project October", "and its figure reads on as the menu's line does")
    expect(ProjectionWording.tooEarlyBasis, "a day of counting is needed first", "the caption says why")
    expect(ProjectionWording(projected: nil, now: london.parseLocal("2026-09-29T21:30")!, cal: cycle15).headline,
           "Too early to project the cycle ending 14 Oct", "a billing cycle names its last day")
    check(!ProjectionWording(projected: Totals(bytesIn: 1), now: freshNow, cal: london).isTooEarly,
          "a figure, however small, is not too early")
    let lines = MenuModel.information(MenuSnapshot(aggregator: Aggregator(db: fresh, cal: london), now: freshNow),
                                      options: menuOptions())
    expect(lines.last, .insight("Too early to project October", bar: nil, toolTip: ProjectionWording.tooEarlyBasis),
           "the menu says it is too early to project, and its tooltip says why")

    let nothing = Aggregator(db: makeDatabase(), cal: london).projection(now: freshNow)
    check(nothing == nil, "with nothing counted at all, it is too early")
    expect(ProjectionWording(projected: nothing, now: freshNow, cal: london).figure, "Too early",
           "and the figure says so")
}

// MARK: - The heatmap averages the last four whole weeks

func checkHeatmapAveragesWholeWeeks() {
    // Thursday 8 October at noon. Every hour of every day carries 60 MB
    // down and 6 MB up, so every cell must read alike: summing 30 days
    // counted two weekdays five times and the rest four.
    let now = london.parseLocal("2026-10-08T12:00")!
    let uniformDB = steadyTraffic(from: "2026-08-29T12:00", to: "2026-10-08T12:00", down: 1_000_000, up: 100_000)
    let uniform = Aggregator(db: uniformDB, cal: london)
    let cells = uniform.heatmap(now: now)
    expect(cells.count, 168, "a cell for every hour of every weekday")
    check(cells.allSatisfy { $0.days == 4 }, "forty days in, every weekday is counted four times")
    check(cells.allSatisfy { $0.average == Totals(bytesIn: 60_000_000, bytesOut: 6_000_000) },
          "and every cell averages 60 MB down and 6 MB up, got \(Set(cells.map(\.average.bytesIn)).sorted())")

    // Counting began at noon ten days before: that day is not whole, so it
    // is left out, and the nine days after count once or twice each.
    let tenDays = Aggregator(db: steadyTraffic(from: "2026-09-28T12:00", to: "2026-10-08T12:00",
                                               down: 1_000_000, up: 100_000), cal: london).heatmap(now: now)
    check(tenDays.allSatisfy { $0.average == Totals(bytesIn: 60_000_000, bytesOut: 6_000_000) },
          "counted for nine whole days, every cell still averages the same, got \(Set(tenDays.map(\.average.bytesIn)).sorted())")
    check(tenDays.allSatisfy { (1...2).contains($0.days) }, "each weekday is counted once or twice")
    expect(tenDays[1 * 24].days, 2, "Tuesday came round twice")
    expect(Totals(bytesIn: 5, estimatedIn: 5).divided(by: 0), Totals(),
           "a weekday never counted averages to nothing, not to a division by zero")

    // A burst this morning: today is not over, so it is in no cell.
    uniformDB.addBuckets([BucketDelta(minute: londonMinute("2026-10-08T10:30"),
                                      iface: "en0", bytesIn: 10_000_000_000, bytesOut: 0)],
                         ssid: ssidPlaceholder, idle: false)
    expect(uniform.heatmap(now: now), cells, "nothing from today is in any cell")
}

// MARK: - The seven-day average counts only whole counted days

func checkSevenDayAverageCountsWholeDays() {
    // 1 MB down in every minute for forty days up to Thursday noon: every
    // whole day is 1,440 MB, and so is every point of a right average.
    let day = 1_440_000_000.0
    let now = london.parseLocal("2026-10-08T12:00")!
    let steadyDB = steadyTraffic(from: "2026-08-29T12:00", to: "2026-10-08T12:00", down: 1_000_000)
    let steady = Aggregator(db: steadyDB, cal: london)
    let series = steady.daily(lastDays: 30, now: now)
    let before = steady.sevenDayAverage(series, now: now)
    expect(before.count, 30, "a point or a gap for every day of the chart")
    expect(before.compactMap { $0 }.count, 23, "points from the seventh day to yesterday")
    check(before.compactMap { $0 }.allSatisfy { $0 == day }, "every point is the steady 1,440 MB, got \(Set(before.compactMap { $0 }))")
    check(before.last! == nil, "today is not over, so it has no point")

    // Asked for the 30 days a chart draws, the averages run over six more,
    // so every whole day in the window has a point, from the first on.
    let charted = steady.dailyWithAverage(lastDays: 30, now: now)
    expect(charted.days.map(\.label), series.map(\.label), "the days are the 30 the chart draws")
    expect(charted.days.map(\.totals), series.map(\.totals), "with the same figures")
    expect(charted.averages.indices.filter { charted.averages[$0] != nil }, Array(0..<29),
           "forty days in, every whole day of the 30 has a point, the first included, and today none")
    check(charted.averages.compactMap { $0 }.allSatisfy { $0 == day }, "and each is the steady 1,440 MB")
    expect(steady.dailyWithAverage(lastDays: 0, now: now).days.count, 0, "no days asked for, none given")

    // Today is left out by the clock, not by its place in the series.
    let toYesterday = Array(steady.daily(lastDays: 31, now: now).dropLast())
    expect(steady.sevenDayAverage(toYesterday, now: now).last, day,
           "a series that ends yesterday, asked today, has a point on its last day")

    // Counting began at 22:00 nine days before: eight whole days, so only
    // the last two whole-week windows have a point.
    let nineNow = london.parseLocal("2026-10-08T22:00")!
    let nine = Aggregator(db: steadyTraffic(from: "2026-09-29T22:00", to: "2026-10-08T22:00", down: 1_000_000), cal: london)
    let nineAverages = nine.sevenDayAverage(nine.daily(lastDays: 30, now: nineNow), now: nineNow)
    expect(nineAverages.indices.filter { nineAverages[$0] != nil }, [27, 28],
           "nine days in, only the two windows of whole counted days have a point")
    let nineCharted = nine.dailyWithAverage(lastDays: 30, now: nineNow).averages
    expect(nineCharted.indices.filter { nineCharted[$0] != nil }, [27, 28], "and the six days more add none before them")
    check(nineAverages.compactMap { $0 }.allSatisfy { $0 == day }, "and neither counts a day before counting as nothing")

    // 7 GB more on 20 September raises the seven points whose window holds
    // that day, each by a seventh of it, and no other.
    steadyDB.addBuckets([BucketDelta(minute: londonMinute("2026-09-20T12:00"),
                                     iface: "en0", bytesIn: 7_000_000_000, bytesOut: 0)], ssid: ssidPlaceholder, idle: false)
    let after = steady.sevenDayAverage(steady.daily(lastDays: 30, now: now), now: now)
    let heavy = series.firstIndex { $0.label == "20 Sep" }!
    let raised = before.indices.filter { before[$0] != after[$0] }
    expect(raised, Array(heavy...(heavy + 6)), "one heavy day raises exactly the seven points whose window holds it")
    check(raised.allSatisfy { (after[$0] ?? 0) - (before[$0] ?? 0) == 1_000_000_000 }, "each by a seventh of the extra")
}

// MARK: - Today against the same time yesterday

func checkTodayAgainstYesterdayAtThisTime() {
    let mb: UInt64 = 1_000_000
    let yesterday = Totals(bytesIn: 1_440 * mb)
    let soFar = Totals(bytesIn: 721 * mb)
    let reached = "at this time, when it had reached 721 MB. Yesterday came to 1.44 GB in all."
    expect(DayComparison.text(today: Totals(bytesIn: 5 * mb), yesterdaySoFar: Totals(), yesterday: Totals()),
           "No figure for yesterday to compare against yet.", "nothing yesterday, nothing to compare")
    expect(DayComparison.text(today: Totals(bytesIn: 5 * mb), yesterdaySoFar: Totals(), yesterday: yesterday),
           "Yesterday had nothing by this time, and came to 1.44 GB in all.", "nothing yesterday by this time")
    expect(DayComparison.text(today: Totals(bytesIn: 800 * mb), yesterdaySoFar: soFar, yesterday: yesterday),
           "Up on yesterday " + reached, "more than five per cent up")
    expect(DayComparison.text(today: Totals(bytesIn: 600 * mb), yesterdaySoFar: soFar, yesterday: yesterday),
           "Down on yesterday " + reached, "more than five per cent down")
    expect(DayComparison.text(today: Totals(bytesIn: 730 * mb, bytesOut: 900 * mb), yesterdaySoFar: soFar, yesterday: yesterday),
           "About the same as yesterday " + reached, "within five per cent, and download only")

    // Two identical days, asked at Thursday noon: the morning against
    // yesterday's morning, not against all of yesterday.
    let now = london.parseLocal("2026-10-08T12:00")!
    let steady = Aggregator(db: steadyTraffic(from: "2026-10-06T00:00", to: "2026-10-08T12:01", down: mb), cal: london)
    expect(london.yesterdayUntil(now), MinuteRange(start: londonMinute("2026-10-07T00:00"),
                                                   end: londonMinute("2026-10-07T12:00") + 1),
           "yesterday until now runs from its midnight to the same minute, that minute included")
    expect(DayComparison.text(today: steady.totals(london.today(now)), yesterdaySoFar: steady.totals(london.yesterdayUntil(now)),
                              yesterday: steady.totals(london.yesterday(now))),
           "About the same as yesterday " + reached, "two identical days read about the same")
}

// MARK: - All time is the sum of samples, without the first-seen lump

func checkAllTimeIsTheSumOfSamples() {
    let db = makeDatabase()
    var baselines: [String: RawCounter] = [:]
    var counter: UInt64 = 5_000_000_000          // the lump already on the interface
    var expectedIn: UInt64 = 0
    var clock: Int64 = 1_789_920_000
    for index in 0..<200 {
        if index > 0 {
            counter += 123_457
            expectedIn += 123_457
        }
        let outcome = Ledger.ingest(readings: [reading("en0", counter, counter / 10)], previous: baselines,
                                    now: clock, reason: .normal, bootTime: nil)
        db.addBuckets(outcome.buckets, ssid: ssidPlaceholder, idle: false)
        for (name, raw) in outcome.baselines { baselines[name] = raw }
        clock += 5
    }
    let aggregator = Aggregator(db: db, cal: london)
    let now = Date(timeIntervalSince1970: TimeInterval(clock + 86_400 * 3))
    let all = aggregator.allTime(now: now)
    var samplesIn: Int64 = 0
    try! db.query("SELECT SUM(bytes_in) FROM samples;") { samplesIn = $0.int(0) }
    expect(all.totals.bytesIn, UInt64(samplesIn), "all time equals the sum of every sample")
    expect(all.totals.bytesIn, expectedIn, "all time is the traffic counted, and leaves out the first-seen lump")
    let firstMinute = aggregator.earliestMinute()!
    expect(all.since, BytemeterCalendar.date(fromMinute: firstMinute), "all time starts at the earliest minute")
    let days = now.timeIntervalSince(BytemeterCalendar.date(fromMinute: firstMinute)) / 86_400
    check(abs(all.days - days) < 0.000_1, "the day count runs from the first minute to now")
    expect(all.perDay.bytesIn, UInt64(Double(expectedIn) / days), "the average per day divides by that day count")

    let empty = Aggregator(db: makeDatabase(), cal: london).allTime(now: now)
    check(empty.since == nil && empty.totals.isEmpty, "with nothing recorded, all time is empty and has no start")
}

// MARK: - As of a moment: the same figures as at that moment

func checkAsOfAMomentMatchesThatMoment() {
    expect(london.parseLocal("2026-10-02T21:30").map { london.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: $0) },
           DateComponents(year: 2026, month: 10, day: 2, hour: 21, minute: 30), "a local time reads in the calendar's zone")
    check(london.parseLocal("2026-10-02T21:30:15") != nil, "seconds are allowed")
    for bad in ["2026-10-02 21:30", "2026-13-02T21:30", "2026-10-02", "21:30", "tomorrow", ""] {
        check(london.parseLocal(bad) == nil, "\"\(bad)\" is refused rather than guessed")
    }

    // Two databases. One runs three days past the moment asked about; the
    // other holds only what existed at that moment. Asked as of the moment,
    // the first must give exactly what the second gives at that moment.
    let asOf = london.parseLocal("2026-10-02T21:30")!
    let asOfMinute = BytemeterCalendar.minute(from: asOf)
    let later = makeDatabase()
    let atTheTime = makeDatabase()
    later.transaction {
        atTheTime.transaction {
            for step in Int64(-8_300)...Int64(620) {
                let minute = asOfMinute + step * 7
                let bucket = BucketDelta(minute: minute, iface: minute % 3 == 0 ? "en1" : "en0",
                                         bytesIn: UInt64(1_000 + (minute % 977) * 1_301),
                                         bytesOut: UInt64(100 + (minute % 89) * 97),
                                         estimated: minute % 11 == 0)
                let procs: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [
                    minute % 2 == 0 ? "Safari" : "Music": (UInt64(minute % 1_000) * 50, 10),
                    "softwareupdated": (UInt64(minute % 37) * 900, 1)]
                later.addBuckets([bucket], ssid: ssidPlaceholder, idle: minute % 5 == 0)
                later.addProcBuckets(minute: minute, deltas: procs)
                if minute <= asOfMinute {
                    atTheTime.addBuckets([bucket], ssid: ssidPlaceholder, idle: minute % 5 == 0)
                    atTheTime.addProcBuckets(minute: minute, deltas: procs)
                }
            }
        }
    }
    let a = Aggregator(db: later, cal: london)
    let b = Aggregator(db: atTheTime, cal: london)
    let cal = london
    for (name, range) in [("today", cal.today(asOf)), ("yesterday", cal.yesterday(asOf)), ("this week", cal.thisWeek(asOf)),
                          ("this month", cal.thisCycle(asOf)), ("last 7 days", cal.rollingDays(7, now: asOf)),
                          ("last 30 days", cal.rollingDays(30, now: asOf))] {
        expect(a.totals(range), b.totals(range), "as of a moment, \(name) matches that moment")
    }
    expect(a.hourly(day: asOf, now: asOf), b.hourly(day: asOf, now: asOf), "as of a moment, the hourly chart stops there")
    check(a.hourly(day: asOf, now: asOf) != a.hourly(day: asOf, now: asOf.addingTimeInterval(7_200)),
          "and it does stop: two hours later the same day reads differently")
    expect(a.daily(lastDays: 30, now: asOf).map(\.totals), b.daily(lastDays: 30, now: asOf).map(\.totals), "the 30 days match")
    expect(a.heatmap(weeks: 4, now: asOf), b.heatmap(weeks: 4, now: asOf), "the heatmap matches")
    expect(a.monthly(now: asOf).map(\.totals), b.monthly(now: asOf).map(\.totals), "month by month matches")
    let allA = a.allTime(now: asOf), allB = b.allTime(now: asOf)
    expect(allA.totals, allB.totals, "all time stops at the moment")
    check(allA.since == allB.since && allA.days == allB.days && allA.perDay == allB.perDay,
          "all time's start, day count and average match")
    check(a.allTime(now: asOf.addingTimeInterval(3 * 86_400)).totals.bytesIn > allA.totals.bytesIn,
          "and the later rows are really there to be left out")
    expect(a.projection(now: asOf), b.projection(now: asOf), "the projection matches")
    let peakHourA = a.peakDownloadHourToday(now: asOf), peakHourB = b.peakDownloadHourToday(now: asOf)
    check(peakHourA?.hour == peakHourB?.hour && peakHourA?.totals == peakHourB?.totals, "the peak hour matches")
    check(a.peakDownloadDayThisCycle(now: asOf)?.totals == b.peakDownloadDayThisCycle(now: asOf)?.totals, "the peak day matches")
    for (name, range) in [("today", cal.today(asOf)), ("this month", cal.thisCycle(asOf))] {
        let ta = a.topTalkers(range, limit: 10), tb = b.topTalkers(range, limit: 10)
        check(ta.map(\.name) == tb.map(\.name) && ta.map(\.totals) == tb.map(\.totals), "top talkers \(name) match")
    }
    let splitA = a.idleSplit(cal.rollingDays(30, now: asOf)), splitB = b.idleSplit(cal.rollingDays(30, now: asOf))
    check(splitA.idle == splitB.idle && splitA.active == splitB.active, "idle against active matches")

    // The menu, line by line, as the demo would build it and as the app would have at that moment.
    let options = menuOptions()
    let menuLater = MenuModel.information(MenuSnapshot(aggregator: a, now: asOf), options: options)
    let menuThen = MenuModel.information(MenuSnapshot(aggregator: b, now: asOf), options: options)
    expect(menuLater, menuThen, "as of a moment, every menu line matches that moment")
    expect(MenuModel.topApps(MenuSnapshot(aggregator: a, now: asOf), options: options),
           MenuModel.topApps(MenuSnapshot(aggregator: b, now: asOf), options: options),
           "and so does every app in Top Apps Today")

    // All time's start and day count moved from a caption to its tooltip.
    // 8,300 steps of 7 minutes before the moment: 40.35 days, from 23 Aug.
    let allTime = menuLater.compactMap { line -> String? in
        if case let .period(.allTime, _, _, _, toolTip) = line { return toolTip } else { return nil }
    }
    expect(allTime, ["Since 23 Aug 2026 · 40.3 days counted"], "all time's tooltip carries its start date and day count")
    let live = MenuModel.information(MenuSnapshot(aggregator: a, now: asOf),
                                     options: menuOptions(liveSpeed: true, rateIn: 2_100_000,
                                                          capEnabled: true, capBytes: 100_000_000_000,
                                                          perAppSampling: false))
    expect(live.first, .header(MenuModel.title, trailing: "↓ 2.1 MB/s"),
           "live speed puts the download rate at the right of the header, not in a row of its own")
    check(live.last.map { if case .insight(_, .some, _) = $0 { return true } else { return false } } == true,
          "with a cap set, the cap's line, with its bar, is the insight")
}

// MARK: - One set of headline figures, and the menu bar's figure is one of them

func checkHeadlinesAreOneSet() {
    // Traffic on four days, so today, the last 7 days, the last 30 days and
    // all time all differ, and a row after the moment that none of them may count.
    let db = makeDatabase()
    addTraffic(db, at: "2026-08-20T10:00", 7_000_000_000, 700_000_000)
    addTraffic(db, at: "2026-09-25T09:00", 3_000_000_000, 300_000_000)    // the last 30 days, not the last 7
    addTraffic(db, at: "2026-10-06T14:00", 2_000_000_000, 200_000_000)
    addTraffic(db, at: "2026-10-08T08:30", 1_000_000_000, 100_000_000)
    addTraffic(db, at: "2026-10-08T15:00", 9_000_000_000, 900_000_000)    // after the moment
    let now = london.parseLocal("2026-10-08T12:00")!
    let aggregator = Aggregator(db: db, cal: london)
    let headlines = Headlines(aggregator: aggregator, now: now)
    let lines = MenuModel.information(MenuSnapshot(aggregator: aggregator, now: now), options: menuOptions())
    let rows = lines.compactMap { line -> (label: String, down: String)? in
        if case let .period(_, label, down, _, _) = line { return (label, down) } else { return nil }
    }
    expect(rows.map(\.label), ["Today", "Last 7 days", "Last 30 days", "All time"],
           "the period rows are the four the menu bar cycles through, in its order")
    let download: [UInt64] = [1_000_000_000, 3_000_000_000, 6_000_000_000, 13_000_000_000]
    for (index, mode) in StatusMode.allCases.enumerated() where index < rows.count {
        let figure = headlines.figure(for: mode)
        expect(figure.totals.bytesIn, download[index], "\(mode.label): the figure is that period's download")
        expect(Units.bytes(figure.totals.bytesIn), rows[index].down,
               "\(mode.label): the menu bar's figure is the row \(rows[index].label)")
        let alone = Headlines.figure(for: mode, aggregator: aggregator, now: now)
        check(alone.totals == figure.totals && alone.since == figure.since,
              "\(mode.label): worked out on its own, as the menu bar does, it is the same figure")
    }
    expect(headlines.figure(for: .allTime).since, london.parseLocal("2026-08-20T10:00"), "all time carries its start date")
    check([StatusMode.today, .last7, .last30].allSatisfy { headlines.figure(for: $0).since == nil },
          "and only all time carries one")
    let none = Aggregator(db: makeDatabase(), cal: london)
    let empty = Headlines.figure(for: .allTime, aggregator: none, now: now)
    check(empty.totals.isEmpty && empty.since == nil && Headlines(aggregator: none, now: now).figure(for: .allTime).since == nil,
          "with nothing counted, all time has no start date")
}

// MARK: - The menu offers the four periods the menu bar cycles through

func checkMenuOffersThePeriods() {
    let offered = MenuModel.periods(current: .last7)
    expect(offered.map(\.mode), StatusMode.allCases, "the menu offers the periods in the order a right-click cycles them")
    expect(offered.map(\.title), ["Today", "Last 7 days", "Last 30 days", "All time"],
           "each under the menu bar's own name for it, as Tokenmeter names them")
    expect(offered.map(\.chosen), [false, true, false, false], "and marks the one showing now, and only that")
}

// MARK: - The menu is four periods, one ticked, in download only

func checkMenuIsFourPeriodsInDownload() {
    // Upload differs from download everywhere, so an upload figure that crept
    // back into the menu would show up as a figure it does not expect.
    let db = makeDatabase()
    addTraffic(db, at: "2026-09-25T10:00", 4_000_000_000, 900_000_000)
    addTraffic(db, at: "2026-09-29T10:00", 3_000_000_000, 700_000_000)
    db.addProcBuckets(minute: londonMinute("2026-09-29T10:00"), deltas: [
        "com.apple.WebKi": (bytesIn: 1_800_000_000, bytesOut: 50_000_000),
        "Backup": (bytesIn: 10_000_000, bytesOut: 2_500_000_000),
        "cloudd": (bytesIn: 300_000_000, bytesOut: 3_000_000)])
    let now = london.parseLocal("2026-09-29T21:30")!
    let headlines = Headlines(aggregator: Aggregator(db: db, cal: london), now: now)
    let snapshot = MenuSnapshot(aggregator: Aggregator(db: db, cal: london), now: now)

    for mode in StatusMode.allCases {
        let lines = MenuModel.information(snapshot, options: menuOptions(statusMode: mode, liveSpeed: true, rateIn: 2_100_000))
        let periods = lines.compactMap { line -> (mode: StatusMode, down: String, chosen: Bool)? in
            if case let .period(mode, _, down, chosen, _) = line { return (mode, down, chosen) } else { return nil }
        }
        expect(periods.map(\.mode), StatusMode.allCases, "with \(mode.label) showing, exactly the four periods, in cycle order")
        expect(periods.filter(\.chosen).map(\.mode), [mode], "and only \(mode.label), the one in the menu bar, is ticked")
        expect(periods.map(\.down), StatusMode.allCases.map { Units.bytes(headlines.figure(for: $0).totals.bytesIn) },
               "each period's one figure is its download")
        let words = lines.map { line -> String in
            switch line {
            case let .header(text, trailing): return text + (trailing ?? "")
            case let .warning(text, toolTip): return text + (toolTip ?? "")
            case let .period(_, label, down, _, toolTip): return label + down + (toolTip ?? "")
            case let .insight(text, _, _): return text
            case .separator: return ""
            }
        }.joined()
        check(!words.contains("↑") && !words.contains("700 MB") && !words.contains("1.60 GB"),
              "no upload figure or upload arrow anywhere in the main menu, got: \(words)")
        check(!lines.contains { if case .warning = $0 { return true } else { return false } },
              "on a normal day there is no warning row")
    }

    let tooltips = MenuModel.information(snapshot, options: menuOptions()).compactMap { line -> String?? in
        if case let .period(_, _, _, _, toolTip) = line { return toolTip } else { return nil }
    }
    expect(tooltips, [nil, "From 23 Sep", "From 31 Aug", "Since 25 Sep 2026 · 4.5 days counted"],
           "each row's tooltip says where it starts, counting today as one of the days")
    let cycle = BytemeterCalendar(timeZone: london.calendar.timeZone, cycleStartDay: 15)
    let onACycle = MenuModel.information(MenuSnapshot(aggregator: Aggregator(db: db, cal: cycle), now: now),
                                         options: menuOptions(statusMode: .last30))
    check(onACycle.contains { line in
        if case .period(.last30, "Last 30 days", _, true, "From 31 Aug") = line { return true } else { return false }
    }, "a billing cycle does not move the rolling 30 days")

    // Top Apps Today: download only, by download, under plain names.
    let apps = MenuModel.topApps(snapshot, options: menuOptions())
    expect(apps?.map(\.name), ["Web content (WebKit)", "iCloud", "Backup"],
           "the apps are listed by download, which the menu shows, not by download and upload together")
    expect(apps?.map(\.down), [Units.bytes(1_800_000_000), Units.bytes(300_000_000), Units.bytes(10_000_000)],
           "each with its download only")
    expect(apps?.first?.share, 1, "the first app's bar is full")
    check(apps.map { $0.allSatisfy { $0.share > 0 && $0.share <= 1 } } == true, "and every other is a share of it")
    check(MenuModel.topApps(snapshot, options: menuOptions(perAppSampling: false)) == nil,
          "with per-app sampling off, the submenu is left out, not shown empty")
}

// MARK: - Plain names for background processes, and only true ones

func checkProcessNames() {
    // The WebKit process loads pages for Mail and other apps too, so calling
    // it Safari would be untrue; a process not in the list must not be renamed.
    expect(ProcessNames.plainNames, ["com.apple.WebKi": "Web content (WebKit)", "cloudd": "iCloud",
                                     "nsurlsessiond": "Background downloads"],
           "the list holds exactly the names agreed")
    for (process, name) in ProcessNames.plainNames {
        expect(ProcessNames.plain(process), name, "\(process) shows as \(name)")
    }
    for process in ["Safari", "mDNSResponder", "com.apple.WebKit", "Cloudd", ""] {
        expect(ProcessNames.plain(process), process, "\(process.debugDescription) keeps its own name")
    }
}

// MARK: - The menu bar's running total is the headline, through every kind of write

/// The menu bar figure keeps the sum of the hours that are over and reads
/// only the current hour each time (`Aggregator.runningTotals`). The headline
/// it must equal is read whole from `samples` every time, so each step below
/// compares the two in all four modes, after each way a row can change, and
/// counts how often the kept sum had to be read again.
func checkMenuBarFigureIsARunningTotal() {
    let db = makeDatabase()
    addTraffic(db, at: "2026-08-20T10:17", 7_000_000_000, 700_000_000)    // off the hour, for the tidy up to move
    addTraffic(db, at: "2026-10-02T09:00", 3_000_000_000, 300_000_000)
    addTraffic(db, at: "2026-10-06T14:00", 2_000_000_000, 200_000_000)
    addTraffic(db, at: "2026-10-08T08:30", 1_000_000_000, 100_000_000)
    addTraffic(db, at: "2026-10-08T12:10", 40_000_000, 4_000_000)
    let aggregator = Aggregator(db: db, cal: london)
    var now = london.parseLocal("2026-10-08T12:20")!

    /// Every mode's running figure against the headline read whole. One
    /// sum is kept at a time, so all time is asked first, while its sum from
    /// the step before is still the one kept, and again last, to leave it
    /// kept for the step after.
    func agrees(_ step: String) {
        let headlines = Headlines(aggregator: aggregator, now: now)
        for mode in [StatusMode.allTime] + StatusMode.allCases {
            let running = Headlines.figure(for: mode, aggregator: aggregator, now: now)
            let whole = headlines.figure(for: mode)
            check(running.totals == whole.totals && running.since == whole.since,
                  "\(step): the menu bar's \(mode.label) is the headline read whole")
        }
    }
    /// All time alone, and how many times its kept sum has been read from the table.
    func allTime(_ step: String, reads expected: Int) {
        let running = Headlines.figure(for: .allTime, aggregator: aggregator, now: now)
        expect(running.totals, aggregator.allTime(now: now).totals, "\(step): all time is the sum of samples")
        expect(db.settledSumsRead, expected, "\(step): the earlier hours have been summed this many times")
    }

    allTime("first asked", reads: 1)
    allTime("asked again", reads: 1)

    // What the sampler does all day: a reading into the current minute.
    addTraffic(db, at: "2026-10-08T12:20", 5_000_000, 500_000)
    allTime("after an ordinary reading", reads: 1)

    // The hour turns. The hour just ended is added to the kept sum.
    now = london.parseLocal("2026-10-08T13:05")!
    addTraffic(db, at: "2026-10-08T13:05", 6_000_000, 600_000)
    allTime("in the next hour", reads: 1)
    expect(Headlines.figure(for: .allTime, aggregator: aggregator, now: now).totals.bytesIn, 13_051_000_000,
           "in the next hour: and it holds every byte so far")

    // Waking fills in the minutes of the sleep, which are in hours already summed.
    addTraffic(db, at: "2026-10-07T03:00", 800_000, 80_000)
    allTime("after a sleep is filled in", reads: 2)

    // A row changed without `writeBuckets`, three ways, each of which SQLite reports.
    let past = londonMinute("2026-10-06T14:00")
    try? db.run("UPDATE samples SET bytes_in=bytes_in+5 WHERE minute=?;", [.int(past)])
    allTime("after an update", reads: 3)
    try? db.run("""
        INSERT INTO samples(minute,iface,ssid,bytes_in,bytes_out) VALUES(?,?,?,?,?)
        ON CONFLICT(minute,iface,ssid) DO UPDATE SET bytes_in=bytes_in+excluded.bytes_in;
        """, [.int(past), .text("en0"), .text(ssidPlaceholder), .int(11), .int(0)])
    allTime("after an insert that lands on a row", reads: 4)
    try? db.run("INSERT INTO samples(minute,iface,ssid,bytes_in,bytes_out) VALUES(?,?,?,?,?);",
                [.int(past + 1), .text("en1"), .text(ssidPlaceholder), .int(13), .int(1)])
    allTime("after a new row", reads: 5)
    try? db.run("DELETE FROM samples WHERE minute=?;", [.int(past + 1)])
    allTime("after a delete", reads: 6)

    // Free-form SQL, which can empty a table without a row being reported.
    try? db.exec("DELETE FROM samples WHERE minute=\(londonMinute("2026-10-07T03:00"));")
    allTime("after exec", reads: 7)

    // A past bucket in a transaction that rolls back changes nothing.
    struct Stop: Error {}
    let silenced = db.log
    db.log = { _ in }
    db.transaction {
        try db.writeBuckets([BucketDelta(minute: past, iface: "en0", bytesIn: 999, bytesOut: 9)],
                            ssid: ssidPlaceholder, idle: false)
        throw Stop()
    }
    db.log = silenced
    agrees("after a write that was rolled back")

    // Another connection, as another process would be.
    check(rawExec(db.path, "UPDATE samples SET bytes_in=bytes_in+17 WHERE minute=\(past);"),
          "the fixture is written by a second connection")
    allTime("after another connection wrote", reads: db.settledSumsRead + 1)

    // The clock put back an hour: the kept sum reaches past the hour asked for.
    now = london.parseLocal("2026-10-08T12:30")!
    agrees("with the clock put back")
    now = london.parseLocal("2026-10-08T13:10")!
    agrees("with the clock put right")

    // A week on, in a new week: every mode has a new start.
    addTraffic(db, at: "2026-10-15T09:00", 70_000_000, 7_000_000)
    now = london.parseLocal("2026-10-15T09:30")!
    agrees("a week later")

    // The tidy up collapses minutes into hours, moving the start of all time
    // to the top of its hour.
    now = london.parseLocal("2026-12-20T09:30")!
    agrees("before the tidy up")
    let collapsed = (try? Maintenance.prune(db: db, now: now, timeZone: TimeZone(identifier: "Europe/London")!)) ?? 0
    check(collapsed > 0, "the tidy up collapses the fixture's oldest rows")
    agrees("after the tidy up")

    // Emptying a table outright is the one change SQLite makes without
    // reporting a row, so `exec`, and `run` for a delete, end the kept sum
    // themselves. The last 30 days keep their start whatever the table
    // holds, so only that can end their sum.
    func month() -> Totals { Headlines.figure(for: .last30, aggregator: aggregator, now: now).totals }
    addTraffic(db, at: "2026-12-05T10:00", 9_000, 900)
    expect(month(), Totals(bytesIn: 9_000, bytesOut: 900), "the month has traffic before the table is emptied")
    try? db.exec("DELETE FROM samples;")
    addTraffic(db, at: "2026-12-20T09:30", 4_321, 432)
    expect(month(), Totals(bytesIn: 4_321, bytesOut: 432), "after the table is emptied: the month holds only what came after")
    addTraffic(db, at: "2026-12-06T10:00", 7_000, 700)
    expect(month(), Totals(bytesIn: 11_321, bytesOut: 1_132), "the month has traffic before the table is emptied again")
    try? db.run("DELETE FROM samples;")
    addTraffic(db, at: "2026-12-20T09:30", 55, 5)
    expect(month(), Totals(bytesIn: 55, bytesOut: 5), "after a delete of every row: the month holds only what came after")

    // A sum whose read failed is not kept, so the next one is read afresh
    // rather than built on it.
    let stretch = MinuteRange(start: londonMinute("2026-12-02T00:00"), end: londonMinute("2026-12-20T09:00"))
    let reads = db.settledSumsRead
    check(db.settledTotals(stretch, sum: { _ in nil }) == nil, "a sum that could not be read comes back as no sum")
    expect(db.settledTotals(stretch, sum: { _ in Totals(bytesIn: 7) }), Totals(bytesIn: 7), "and the next is read, not taken from it")
    expect(db.settledTotals(stretch, sum: { _ in Totals(bytesIn: 8) }), Totals(bytesIn: 7), "a sum that was read is the one kept")
    expect(db.settledSumsRead, reads + 2, "so the failed read and the one after it each went to the table")
    let longer = MinuteRange(start: stretch.start, end: stretch.end + 60)
    check(db.settledTotals(longer, sum: { _ in nil }) == nil, "an hour that could not be added leaves no sum")
    expect(db.settledTotals(longer, sum: { _ in Totals(bytesIn: 9) }), Totals(bytesIn: 9), "and the whole stretch is read again")

    // A figure within the current hour has nothing to keep and is read whole.
    let fresh = makeDatabase()
    addTraffic(fresh, at: "2026-10-08T12:10", 1_000, 100)
    let young = Aggregator(db: fresh, cal: london)
    let early = london.parseLocal("2026-10-08T12:20")!
    expect(Headlines.figure(for: .allTime, aggregator: young, now: early).totals.bytesIn, 1_000,
           "a figure that began this hour is read whole")
    expect(fresh.settledSumsRead, 0, "and keeps nothing")
}

// MARK: - One fetch of minute rows gives the views each fetching its own would

/// A series as text, label, date and figures, so two can be compared whole.
private func seriesText(_ series: [LabelledTotals]) -> [String] {
    series.map { "\($0.label) \($0.date.timeIntervalSince1970) \($0.totals)" }
}

private func peakText(_ peak: (hour: Int, totals: Totals)?) -> String {
    peak.map { "\($0.hour) \($0.totals)" } ?? "none"
}

func checkOneFetchGivesTheSameViews() {
    // Six weeks of traffic every 37 minutes, upload, idle and spread minutes
    // among it, over London's clock change on 25 Oct, with rows after every
    // moment asked below as well as before it.
    let db = makeDatabase()
    let first = londonMinute("2026-09-20T19:10")
    var minute = first
    while minute < londonMinute("2026-11-04T00:00") {
        let amount = UInt64((minute % 9_973) * 1_000 + 1)
        db.addBuckets([BucketDelta(minute: minute, iface: "en0", bytesIn: amount, bytesOut: amount / 7,
                                   estimated: minute % 11 == 0)],
                      ssid: ssidPlaceholder, idle: minute % 5 == 0)
        minute += 37
    }
    let newYork = BytemeterCalendar(timeZone: TimeZone(identifier: "America/New_York")!, cycleStartDay: 15)
    let cycle28 = BytemeterCalendar(timeZone: TimeZone(identifier: "Europe/London")!, cycleStartDay: 28)
    let moments: [(BytemeterCalendar, String)] = [
        (london, "2026-10-31T23:50"),   // a 31 day month, its clock change inside it
        (london, "2026-10-25T12:00"),   // the day the clocks go back
        (london, "2026-10-26T01:30"),   // the day after, at a time that happened twice the night before
        (london, "2026-11-01T00:00"),   // the first minute of a month
        (london, "2026-09-21T10:00"),   // the morning after counting began
        (london, "2026-09-20T18:00"),   // before anything was counted
        (cycle28, "2026-10-27T21:30"),  // the last day of a billing cycle
        (newYork, "2026-11-01T12:00"),  // New York's clock change, on a cycle from the 15th
    ]
    // A row on every edge each view cuts at: the first minute of the five
    // weeks, of today and of the cycle, the minute asked at and the one after
    // it. Every 37 minutes lands on almost none of them, and a slice of the
    // shared rows that is a minute out would show only here.
    for (cal, text) in moments {
        let now = cal.parseLocal(text)!
        let at = BytemeterCalendar.minute(from: now)
        let edges = [cal.rollingDays(36, now: now).start, cal.today(now).start, cal.thisCycle(now).start,
                     cal.rollingDays(36, now: now).end - 1, at, at + 1]
        for edge in Set(edges) {
            db.addBuckets([BucketDelta(minute: edge, iface: "en0", bytesIn: 3_000_000_000 + UInt64(edge % 977),
                                       bytesOut: 1_000, estimated: false)],
                          ssid: ssidPlaceholder, idle: false)
        }
    }
    for (cal, text) in moments {
        let now = cal.parseLocal(text)!
        let zone = "\(cal.calendar.timeZone.identifier) at \(text), cycle from \(cal.cycleStartDay)"
        let aggregator = Aggregator(db: db, cal: cal)
        // The stretch the dashboard fetches, and a day too short for most views.
        for (fetched, what) in [(aggregator.fetchMinutes(cal.rollingDays(36, now: now)), "the dashboard's five weeks"),
                                (aggregator.fetchMinutes(cal.today(now)), "today alone")] {
            let hours = aggregator.hourly(day: now, now: now, from: fetched)
            expect(hours, aggregator.hourly(day: now, now: now), "\(zone), from \(what): today's hours")
            // Yesterday's hours as of three days ago, a range that would end
            // before it starts. MinuteRange closes it up, so the shared rows
            // can never be sliced backwards; this holds that to the database.
            let yesterday = now.addingTimeInterval(-86_400)
            let before = now.addingTimeInterval(-3 * 86_400)
            expect(aggregator.hourly(day: yesterday, now: before, from: fetched), aggregator.hourly(day: yesterday, now: before),
                   "\(zone), from \(what): a day after the moment asked holds nothing, rather than trapping")
            expect(seriesText(aggregator.daily(lastDays: 36, now: now, from: fetched)),
                   seriesText(aggregator.daily(lastDays: 36, now: now)), "\(zone), from \(what): the daily series")
            let shared = aggregator.dailyWithAverage(lastDays: 30, now: now, from: fetched)
            let alone = aggregator.dailyWithAverage(lastDays: 30, now: now)
            check(seriesText(shared.days) == seriesText(alone.days) && shared.averages == alone.averages,
                  "\(zone), from \(what): the 30 days and their seven-day average")
            expect(aggregator.heatmap(weeks: 4, now: now, from: fetched), aggregator.heatmap(weeks: 4, now: now),
                   "\(zone), from \(what): the heatmap")
            expect(seriesText(aggregator.peakDownloadDayThisCycle(now: now, from: fetched).map { [$0] } ?? []),
                   seriesText(aggregator.peakDownloadDayThisCycle(now: now).map { [$0] } ?? []),
                   "\(zone), from \(what): the peak day this cycle")
            let passed = Headlines(aggregator: aggregator, now: now, hourlyToday: hours, from: fetched)
            let worked = Headlines(aggregator: aggregator, now: now)
            expect(peakText(passed.peakHour), peakText(worked.peakHour), "\(zone), from \(what): the headline peak hour")
            expect(seriesText(passed.peakDay.map { [$0] } ?? []), seriesText(worked.peakDay.map { [$0] } ?? []),
                   "\(zone), from \(what): the headline peak day")
        }
    }
    // The fixture is not empty where it matters, or the checks above prove little.
    let busy = Aggregator(db: db, cal: london)
    let late = london.parseLocal("2026-10-31T23:50")!
    check(busy.peakDownloadDayThisCycle(now: late) != nil && busy.peakDownloadHourToday(now: late) != nil
          && busy.heatmap(weeks: 4, now: late).allSatisfy { $0.days == 4 && !$0.totals.isEmpty },
          "the fixture has a peak day, a peak hour and four counted weeks in every heatmap cell")
}

// MARK: - The cap shows the real percentage, and what is left or over

func checkCapSaysWhatIsLeftOrOver() {
    let gb: UInt64 = 1_000_000_000
    let cap = 60 * gb
    let cycle15 = BytemeterCalendar(timeZone: london.calendar.timeZone, cycleStartDay: 15)
    func progress(_ used: UInt64, at local: String = "2026-09-29T21:30", cal: BytemeterCalendar = london) -> CapProgress {
        CapProgress(used: used, cap: cap, now: cal.parseLocal(local)!, cal: cal)
    }

    // 29 September at 21:30: today and the 30th are left, so 2 days to go.
    let part = progress(27 * gb)
    expect(part.percent, 45, "27 GB of 60 GB is 45%")
    expect(part.menuText, "27.0 of 60.0 GB, 2 days left", "the menu says what is used of the cap, and for how long")
    expect(part.barFill, 0.45, "and fills its bar to the percentage")
    expect(part.remainingText, "33.0 GB left, 2 days to go", "and says what is left and for how long")

    let nearly = progress(59_994_000_000)
    expect(nearly.percent, 99, "99.99% reads 99%: the cap is not reached until it is")
    expect(nearly.menuText, "60.0 of 60.0 GB, 2 days left", "the menu still gives days left, not the cap reached")
    expect(nearly.remainingText, "6.0 MB left, 2 days to go", "and what is left, however little")
    // The bar rounds down like the percentage: it is full only from the cap on.
    expect(nearly.barFill, 0.99, "at 99.99% the bar is 99% full, not full")
    expect(progress(57_540_000_000).barFill, 0.95, "and at 95.9%, where rounding to the nearest filled it, 95%")
    expect(progress(54_999_999_999).barFill, 0.91, "just under 11/12 is 91%")

    let reached = progress(cap)
    expect(reached.percent, 100, "exactly the cap is 100%")
    expect(reached.remainingText, "Cap reached", "exactly the cap says it is reached")
    expect(reached.barFill, 1, "and the bar is full")
    expect(reached.menuText, "60.0 of 60.0 GB, cap reached", "and the menu says so")

    let over = progress(90 * gb)
    expect(over.percent, 150, "90 GB of 60 GB is 150%, not held at 100%")
    expect(over.fraction, 1.5, "the fraction is not clamped either")
    expect(over.barFill, 1, "the bar stops at full")
    expect(over.menuText, "90.0 of 60.0 GB, 30.0 GB over the cap", "while the figure goes on, and says how far over")
    expect(progress(820_000_000).menuText, "820 MB of 60.0 GB, 2 days left",
           "a figure in another unit keeps its unit, so it cannot read as 820 GB")
    expect(over.remainingText, "30.0 GB over the cap", "and it says how far over")

    expect(CapProgress(used: 29, cap: 100, now: Date(), cal: london).percent, 29,
           "29 of 100 is 29%, worked out in whole numbers, where floating point gives 28.999...")
    let absurd = CapProgress(used: .max, cap: 1, now: Date(), cal: london)
    check(absurd.percent == Int.max && absurd.barFill == 1, "an absurd figure is held at the largest, with no trap")

    // Days to go run from today to the cycle's last day, both counted.
    expect(progress(gb, at: "2026-09-30T00:00").remainingText, "59.0 GB left, 1 day to go",
           "on the month's last day there is 1 day to go")
    expect(progress(gb, at: "2026-09-30T23:59").remainingText, "59.0 GB left, 1 day to go", "up to its last minute")
    expect(progress(gb, at: "2026-09-01T00:00").remainingText, "59.0 GB left, 30 days to go",
           "on the month's first day, the whole month is to go")
    expect(progress(52 * gb, cal: cycle15).remainingText, "8.00 GB left, 16 days to go",
           "a cycle from the 15th, seen on 29 September, runs to 14 October: 16 days")
    expect(progress(gb, at: "2026-10-14T12:00", cal: cycle15).remainingText, "59.0 GB left, 1 day to go",
           "the cycle's last day is the 14th")
    expect(progress(gb, at: "2026-10-15T00:00", cal: cycle15).remainingText, "59.0 GB left, 31 days to go",
           "and the next cycle starts on the 15th, 31 days to 14 November")
    expect(progress(gb, at: "2026-10-20T12:00").remainingText, "59.0 GB left, 12 days to go",
           "October's extra hour from the clock change makes no extra day")

    // The cap's line replaces the projection only with the cap on and above
    // 0, and counts download and upload together, as a provider does.
    let db = makeDatabase()
    db.addBuckets([BucketDelta(minute: londonMinute("2026-09-10T09:00"), iface: "en0",
                               bytesIn: 50 * gb, bytesOut: 2 * gb)], ssid: ssidPlaceholder, idle: false)
    let snapshot = MenuSnapshot(aggregator: Aggregator(db: db, cal: london), now: london.parseLocal("2026-09-29T21:30")!)
    func insight(capEnabled: Bool, capBytes: UInt64) -> MenuLine? {
        MenuModel.information(snapshot, options: menuOptions(capEnabled: capEnabled, capBytes: capBytes)).last
    }
    let projection = MenuLine.insight(snapshot.projection.headline, bar: nil, toolTip: ProjectionWording.basis)
    expect(insight(capEnabled: false, capBytes: cap), projection, "with the cap off, the menu shows the projection")
    expect(insight(capEnabled: true, capBytes: 0), projection, "and with no figure set, too")
    expect(insight(capEnabled: true, capBytes: cap),
           .insight("52.0 of 60.0 GB, 2 days left", bar: 0.86, toolTip: CapProgress.basis),
           "with a cap set, its line and bar replace the projection, counting 52 GB down and up, not the 50 GB down")
}

// MARK: - The menu says when counting has only just started

func checkMenuSaysCountingHasJustStarted() {
    let db = makeDatabase()
    let now = london.parseLocal("2026-10-08T12:00")!
    let options = menuOptions(liveSpeed: true)
    func menu() -> [MenuLine] {
        MenuModel.information(MenuSnapshot(aggregator: Aggregator(db: db, cal: london), now: now), options: options)
    }
    let started = MenuLine.warning("Counting has started: the first figures appear within a minute.", toolTip: nil)
    let header = MenuLine.header(MenuModel.title, trailing: "↓ 0 B/s")

    expect(Array(menu().prefix(2)), [header, started],
           "before a byte is booked, the menu says under its header that counting has started")
    db.addBuckets([BucketDelta(minute: BytemeterCalendar.minute(from: now), iface: "en0", bytesIn: 1, bytesOut: 0)],
                  ssid: ssidPlaceholder, idle: false)
    let counted = menu()
    check(!counted.contains(started), "once a byte is booked, the line is gone")
    expect(counted.filter { if case .warning = $0 { return true } else { return false } }, [],
           "and on a normal day there is no warning row at all")

    // Nothing booked and writes failing: the line says why nothing is being
    // booked, rather than that it soon will be.
    let failing = makeDatabase()
    failing.log = { _ in }
    failing.clock = { now }
    check(!failing.transaction { throw BytemeterError.sql("INSERT", "simulated failure") }, "a write fails")
    let lines = MenuModel.information(MenuSnapshot(aggregator: Aggregator(db: failing, cal: london), now: now),
                                      options: options)
    check(!lines.contains(started) && lines.dropFirst().first.map { line in
        if case let .warning(text, _) = line { return text.hasPrefix("Not recording since 8 Oct 2026 at 12:00") }
        return false
    } == true, "with nothing booked and writes failing, the menu says recording has stopped instead")
}

