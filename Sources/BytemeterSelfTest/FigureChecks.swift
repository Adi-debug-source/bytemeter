import Foundation
import BytemeterCore

// Checks for the figures the menu and the dashboard show: the units, top
// talkers, the menu bar modes, averages, the projection, the heatmap, the
// seven day average, the comparison with yesterday, month by month, all
// time, the figures as of a moment, and the headline set.

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
    expect(StatusMode.today.next, StatusMode.week, "clicking today gives this week")
    expect(StatusMode.week.next, StatusMode.month, "clicking this week gives this month")
    expect(StatusMode.month.next, StatusMode.allTime, "clicking this month gives all time")
    expect(StatusMode.allTime.next, StatusMode.today, "clicking all time comes back to today")
    expect(StatusMode.allCases.count, 4, "four positions in the cycle")
    expect(StatusMode(rawValue: "month"), StatusMode.month, "the saved mode round trips")
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
    stray.addBuckets([BucketDelta(minute: BytemeterCalendar.minute(from: london.parseLocal("2001-01-01T10:00")!), iface: "en0",
                                  bytesIn: 5, bytesOut: 0),
                      BucketDelta(minute: BytemeterCalendar.minute(from: london.parseLocal("2026-03-15T10:00")!), iface: "en0",
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

// MARK: - Averages and the projection count from when counting began

func checkAveragesCountFromWhenCountingBegan() {
    let megabyte: UInt64 = 1_000_000
    /// 1 MB in every minute from `began` up to `now`: 60 MB an hour, 1.44 GB a day.
    func steady(_ began: String, _ now: String) -> (Aggregator, Date) {
        let db = makeDatabase()
        let end = london.parseLocal(now)!
        var rows: [BucketDelta] = []
        var minute = BytemeterCalendar.minute(from: london.parseLocal(began)!)
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
    near(month.projection(now: monthNow).projected?.bytesIn ?? 0, soFar * runway,
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

    // The menu and the dashboard read the same figures.
    let snapshot = MenuSnapshot(aggregator: month, now: monthNow)
    expect(snapshot.perDayMonth, month.averagePerDay(london.thisCycle(monthNow), now: monthNow), "the menu's per day this month")
    expect(snapshot.perDayWeek, month.averagePerDay(london.thisWeek(monthNow), now: monthNow), "the menu's per day this week")
    expect(snapshot.perHourToday, month.averagePerHourToday(now: monthNow), "the menu's per hour today")
    expect(snapshot.projection, ProjectionWording(projected: month.projection(now: monthNow).projected, now: monthNow, cal: london),
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
        within(month.projection(now: now).projected, cycleMB(london, now),
               "at \(at) the projection runs the real rate to the end of the month")
    }
    let cycle15 = BytemeterCalendar(timeZone: london.calendar.timeZone, cycleStartDay: 15)
    let cycleNow = cycle15.parseLocal("2026-10-15T06:00")!
    within(Aggregator(db: db, cal: cycle15).projection(now: cycleNow).projected, cycleMB(cycle15, cycleNow),
           "and so it does on the first morning of a billing cycle")

    // A new install with under a day counted has nothing to run on.
    let fresh = steadyTraffic(from: "2026-10-02T10:00", to: "2026-10-02T16:00", down: 1_000_000)
    let freshNow = london.parseLocal("2026-10-02T16:00")!
    let early = Aggregator(db: fresh, cal: london).projection(now: freshNow)
    check(early.projected == nil, "six hours after counting began, it is too early to project")
    let wording = ProjectionWording(projected: early.projected, now: freshNow, cal: london)
    check(wording.isTooEarly, "the wording knows it is too early")
    expect(wording.figure, "Too early", "the tile's figure says too early")
    expect(wording.headline, "Too early to project October", "the menu's line names the month in full")
    expect(wording.deadline, "by the end of October", "the deadline is still named, as the tile's qualifier")
    expect(ProjectionWording.tooEarlyBasis, "a day of counting is needed first", "the caption says why")
    expect(ProjectionWording(projected: nil, now: london.parseLocal("2026-09-29T21:30")!, cal: cycle15).headline,
           "Too early to project the cycle ending 14 Oct", "a billing cycle names its last day")
    check(!ProjectionWording(projected: Totals(bytesIn: 1), now: freshNow, cal: london).isTooEarly,
          "a figure, however small, is not too early")
    let lines = MenuModel.information(MenuSnapshot(aggregator: Aggregator(db: fresh, cal: london), now: freshNow),
                                      options: MenuModel.Options(liveSpeed: false, rateIn: 0, rateOut: 0,
                                                                 capEnabled: false, capBytes: 0, perAppSampling: true))
    if let index = lines.firstIndex(of: .text("Too early to project October")), index + 1 < lines.count {
        expect(lines[index + 1], .caption(ProjectionWording.tooEarlyBasis), "the menu says why, under the line")
    } else {
        check(false, "the menu says it is too early to project")
    }

    let nothing = Aggregator(db: makeDatabase(), cal: london).projection(now: freshNow)
    check(nothing.projected == nil, "with nothing counted at all, it is too early")
    expect(ProjectionWording(projected: nothing.projected, now: freshNow, cal: london).figure, "Too early",
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
    uniformDB.addBuckets([BucketDelta(minute: BytemeterCalendar.minute(from: london.parseLocal("2026-10-08T10:30")!),
                                      iface: "en0", bytesIn: 10_000_000_000, bytesOut: 0)],
                         ssid: ssidPlaceholder, idle: false)
    expect(uniform.heatmap(now: now), cells, "nothing from today is in any cell")
}

// MARK: - The seven day average counts only whole counted days

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

    // Counting began at 22:00 nine days before: eight whole days, so only
    // the last two whole-week windows have a point.
    let nineNow = london.parseLocal("2026-10-08T22:00")!
    let nine = Aggregator(db: steadyTraffic(from: "2026-09-29T22:00", to: "2026-10-08T22:00", down: 1_000_000), cal: london)
    let nineAverages = nine.sevenDayAverage(nine.daily(lastDays: 30, now: nineNow), now: nineNow)
    expect(nineAverages.indices.filter { nineAverages[$0] != nil }, [27, 28],
           "nine days in, only the two windows of whole counted days have a point")
    check(nineAverages.compactMap { $0 }.allSatisfy { $0 == day }, "and neither counts a day before counting as nothing")

    // 7 GB more on 20 September raises the seven points whose window holds
    // that day, each by a seventh of it, and no other.
    steadyDB.addBuckets([BucketDelta(minute: BytemeterCalendar.minute(from: london.parseLocal("2026-09-20T12:00")!),
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
    expect(london.yesterdayUntil(now), MinuteRange(start: BytemeterCalendar.minute(from: london.parseLocal("2026-10-07T00:00")!),
                                                   end: BytemeterCalendar.minute(from: london.parseLocal("2026-10-07T12:00")!) + 1),
           "yesterday until now runs from its midnight to the same minute, that minute included")
    expect(DayComparison.text(today: steady.totals(london.today(now)), yesterdaySoFar: steady.totals(london.yesterdayUntil(now)),
                              yesterday: steady.totals(london.yesterday(now))),
           "About the same as yesterday " + reached, "two identical days read about the same")
}

// MARK: - All time is the sum of samples, without the first-seen lump

func checkAllTimeIsTheSumOfSamples() {
    let db = makeDatabase()
    var baselines: [String: RawCounter] = [:]
    var counter: UInt64 = 4_770_858_429          // the lump already on the interface
    var expectedIn: UInt64 = 0
    var clock: Int64 = 1_789_924_808
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
    expect(a.projection(now: asOf).projected, b.projection(now: asOf).projected, "the projection matches")
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
    let options = MenuModel.Options(liveSpeed: false, rateIn: 0, rateOut: 0, capEnabled: false, capBytes: 0,
                                    perAppSampling: true)
    let menuLater = MenuModel.information(MenuSnapshot(aggregator: a, now: asOf), options: options)
    let menuThen = MenuModel.information(MenuSnapshot(aggregator: b, now: asOf), options: options)
    expect(menuLater, menuThen, "as of a moment, every menu line matches that moment")

    // The rule for the rows: the four totals in the click cycle are full
    // contrast, and nothing else is.
    let strong = menuLater.compactMap { line -> String? in
        if case let .figure(label, _, _, true) = line { return label } else { return nil }
    }
    expect(strong, ["Today", "This week, from Monday", "This month, from 1 Oct", "All time"],
           "exactly the four cycle rows are full contrast, in order")
    // 8,300 steps of 7 minutes before the moment: 40.35 days, from 23 Aug.
    check(menuLater.contains(.caption("since 23 Aug 2026 · 40.3 days counted")),
          "all time carries its start date and day count, got: \(menuLater.compactMap { if case let .caption(t) = $0 { return t } else { return nil } })")
    check(menuLater.contains { if case .figure("Per day, all time", _, _, false) = $0 { return true } else { return false } },
          "the all time average is a grey row in Averages")
    expect(MenuModel.hint, "Right-click, two-finger click or Control-click the figure to cycle today, week, month and all time.",
           "the hint names the new clicks and all four modes")
    let live = MenuModel.information(MenuSnapshot(aggregator: a, now: asOf),
                                     options: MenuModel.Options(liveSpeed: true, rateIn: 2_100_000, rateOut: 0,
                                                                capEnabled: true, capBytes: 100_000_000_000,
                                                                perAppSampling: false))
    expect(Array(live.prefix(2)), [.header("Live"), .figure(label: "Now", down: "2.1 MB/s", up: "0 B/s", strong: false)],
           "live speed adds a grey Now row at the top")
    check(live.contains(.header("Cap")) && live.contains(.text("Per-app sampling is off")),
          "the cap row and the per-app note follow the settings")
}

// MARK: - One set of headline figures, and the menu bar's figure is one of them

func checkHeadlinesAreOneSet() {
    // Traffic on four days, so today, this week, this month and all time all
    // differ, and a row after the moment that none of them may count.
    let db = makeDatabase()
    func at(_ local: String, _ bytesIn: UInt64, _ bytesOut: UInt64) {
        db.addBuckets([BucketDelta(minute: BytemeterCalendar.minute(from: london.parseLocal(local)!), iface: "en0",
                                   bytesIn: bytesIn, bytesOut: bytesOut)], ssid: ssidPlaceholder, idle: false)
    }
    at("2026-08-20T10:00", 7_000_000_000, 700_000_000)
    at("2026-10-02T09:00", 3_000_000_000, 300_000_000)    // a Friday: this month, not this week
    at("2026-10-06T14:00", 2_000_000_000, 200_000_000)
    at("2026-10-08T08:30", 1_000_000_000, 100_000_000)
    at("2026-10-08T15:00", 9_000_000_000, 900_000_000)    // after the moment
    let now = london.parseLocal("2026-10-08T12:00")!
    let aggregator = Aggregator(db: db, cal: london)
    let headlines = Headlines(aggregator: aggregator, now: now)
    let lines = MenuModel.information(MenuSnapshot(aggregator: aggregator, now: now), options: MenuModel.Options(
        liveSpeed: false, rateIn: 0, rateOut: 0, capEnabled: false, capBytes: 0, perAppSampling: true))
    let strong = lines.compactMap { line -> (label: String, down: String, up: String)? in
        if case let .figure(label, down, up, true) = line { return (label, down, up) } else { return nil }
    }
    expect(strong.map(\.label), ["Today", "This week, from Monday", "This month, from 1 Oct", "All time"],
           "the strong rows are the four the menu bar cycles through, in its order")
    let download: [UInt64] = [1_000_000_000, 3_000_000_000, 6_000_000_000, 13_000_000_000]
    for (index, mode) in StatusMode.allCases.enumerated() where index < strong.count {
        let figure = headlines.figure(for: mode)
        expect(figure.totals.bytesIn, download[index], "\(mode.label): the figure is that period's download")
        expect([Units.bytes(figure.totals.bytesIn), Units.bytes(figure.totals.bytesOut)], [strong[index].down, strong[index].up],
               "\(mode.label): the menu bar's figure is the strong row \(strong[index].label)")
        let alone = Headlines.figure(for: mode, aggregator: aggregator, now: now)
        check(alone.totals == figure.totals && alone.since == figure.since,
              "\(mode.label): worked out on its own, as the menu bar does, it is the same figure")
    }
    expect(headlines.figure(for: .allTime).since, london.parseLocal("2026-08-20T10:00"), "all time carries its start date")
    check([StatusMode.today, .week, .month].allSatisfy { headlines.figure(for: $0).since == nil },
          "and only all time carries one")
    let none = Aggregator(db: makeDatabase(), cal: london)
    let empty = Headlines.figure(for: .allTime, aggregator: none, now: now)
    check(empty.totals.isEmpty && empty.since == nil && Headlines(aggregator: none, now: now).figure(for: .allTime).since == nil,
          "with nothing counted, all time has no start date")
}
