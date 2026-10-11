import Foundation
import BytemeterCore

// Checks for the calendar's days, weeks and hours where they are awkward:
// the week's first day, a clock change that skips midnight, the hour a
// clock change repeats or skips, and the same time yesterday.

// MARK: - The week starts on Monday

func checkWeekStartsOnMonday() {
    var components = DateComponents()
    components.year = 2026; components.month = 9; components.day = 20; components.hour = 12
    let saturday = london.calendar.date(from: components)!
    let start = london.startOfWeek(saturday)
    expect(london.calendar.component(.weekday, from: start), 2, "the week starts on Monday")
    expect(london.calendar.component(.day, from: start), 14, "the Monday of the week containing Sun 20 Sep 2026 is the 14th")
}

// MARK: - Days where a clock change skips midnight

func checkSkippedMidnightsKeepEachDay() {
    for (zone, day) in [("America/Santiago", "2026-09-06"), ("Africa/Cairo", "2026-04-24"), ("America/Havana", "2026-03-08")] {
        let cal = BytemeterCalendar(timeZone: TimeZone(identifier: zone)!)
        let changeDay = cal.parseLocal(day + "T12:00")!
        expect(cal.calendar.component(.hour, from: cal.startOfDay(changeDay)), 1, "\(zone) skips midnight on \(day)")

        // A different amount 30 minutes into each of seven days around the change.
        let db = makeDatabase()
        let first = cal.startOfDay(changeDay, offsetBy: -3)
        var expected: [UInt64] = []
        for n in 0..<7 {
            let amount = UInt64(1_000_000 * (n + 1))
            let at = cal.startOfDay(first, offsetBy: n).addingTimeInterval(30 * 60)
            db.addBuckets([BucketDelta(minute: BytemeterCalendar.minute(from: at), iface: "en0", bytesIn: amount, bytesOut: 0)],
                          ssid: ssidPlaceholder, idle: false)
            expected.append(amount)
        }
        let agg = Aggregator(db: db, cal: cal)
        let now = cal.startOfDay(first, offsetBy: 7).addingTimeInterval(6 * 3_600)
        let series = agg.daily(lastDays: 8, now: now)
        expect(series.map(\.totals.bytesIn), expected + [0], "\(zone): each day's traffic stays in its own day after the change")
        let yesterdays = (0..<7).map { n in
            agg.totals(cal.yesterday(cal.startOfDay(first, offsetBy: n + 1).addingTimeInterval(12 * 3_600))).bytesIn
        }
        expect(yesterdays, expected, "\(zone): every daily figure matches totals(yesterday) asked the day after")
        let starts = cal.dayStarts(from: first, dayCount: 7).map(BytemeterCalendar.date(fromMinute:))
        check(starts.allSatisfy { cal.startOfDay($0) == $0 }, "\(zone): every day start is the start of its day")
        check(zip(starts, starts.dropFirst()).allSatisfy { cal.daysBetween($0, $1) == 1 }, "\(zone): one day apart each")
        // The first day's traffic is 30 minutes in, so a row at its start
        // makes it a whole counted day for the heatmap's week.
        db.addBuckets([BucketDelta(minute: BytemeterCalendar.minute(from: first), iface: "en0", bytesIn: 0, bytesOut: 0)],
                      ssid: ssidPlaceholder, idle: false)
        expect(agg.heatmap(weeks: 1, now: now).reduce(UInt64(0)) { $0 + $1.totals.bytesIn }, expected.reduce(0, +),
               "\(zone): the heatmap counts every byte once")
        expect(agg.hourly(day: changeDay, now: now).reduce(UInt64(0)) { $0 + $1.bytesIn }, expected[3],
               "\(zone): the change day's hours hold its own traffic and none of the next day's")
    }

    let santiago = BytemeterCalendar(timeZone: TimeZone(identifier: "America/Santiago")!)
    expect(santiago.yesterday(santiago.parseLocal("2026-09-06T12:00")!).start,
           BytemeterCalendar.minute(from: santiago.parseLocal("2026-09-05T00:00")!),
           "yesterday, asked on the day of the change, starts at the previous midnight")
    expect(santiago.rollingDays(2, now: santiago.parseLocal("2026-09-06T12:00")!).start,
           BytemeterCalendar.minute(from: santiago.parseLocal("2026-09-05T00:00")!),
           "so does a rolling window")
    let cycle6 = BytemeterCalendar(timeZone: TimeZone(identifier: "America/Santiago")!, cycleStartDay: 6)
    expect(cycle6.endOfCycle(santiago.parseLocal("2026-09-15T12:00")!), santiago.parseLocal("2026-10-06T00:00")!,
           "a cycle that begins on a skipped midnight ends at the next cycle's real midnight")
    let peakDB = makeDatabase()
    peakDB.addBuckets([BucketDelta(minute: BytemeterCalendar.minute(from: santiago.parseLocal("2026-09-06T10:00")!),
                                   iface: "en0", bytesIn: 5_000_000, bytesOut: 0)], ssid: ssidPlaceholder, idle: false)
    expect(Aggregator(db: peakDB, cal: cycle6).peakDownloadDayThisCycle(now: santiago.parseLocal("2026-09-07T00:30")!)?.label,
           "6 Sep", "the cycle's first day still counts when it began on a skipped midnight")
}

// MARK: - Hours on a clock change day

func checkClockChangeHoursKeepTheirSlot() {
    let db = makeDatabase()
    let aggregator = Aggregator(db: db, cal: london)
    for text in ["2026-10-25T15:20", "2026-03-29T15:20"] {
        let at = london.parseLocal(text)!
        db.addBuckets([BucketDelta(minute: BytemeterCalendar.minute(from: at), iface: "en0", bytesIn: 9_000_000, bytesOut: 0)],
                      ssid: ssidPlaceholder, idle: false)
        let later = at.addingTimeInterval(3 * 3_600)
        expect(aggregator.peakDownloadHourToday(now: later)?.hour, 15, "traffic at 15:20 on \(text.prefix(10)) peaks at 15:00")
        expect(aggregator.hourly(day: at, now: later)[15].bytesIn, 9_000_000, "and sits in the 15:00 slot")
        // A row at the day's start, so the heatmap counts the whole day, asked the day after.
        db.addBuckets([BucketDelta(minute: BytemeterCalendar.minute(from: london.startOfDay(at)), iface: "en0",
                                   bytesIn: 0, bytesOut: 0)], ssid: ssidPlaceholder, idle: false)
        expect(aggregator.heatmap(weeks: 1, now: at.addingTimeInterval(86_400))[6 * 24 + 15].totals.bytesIn, 9_000_000,
               "and in Sunday's 15:00 cell of the heatmap")
    }
    // 25 Oct 2026: 01:30 happens twice, at 00:30 and 01:30 UTC. Both are the 01:00 slot.
    let back = makeDatabase()
    back.addBuckets([BucketDelta(minute: 1_792_888_200 / 60, iface: "en0", bytesIn: 1_000, bytesOut: 0),
                     BucketDelta(minute: 1_792_891_800 / 60, iface: "en0", bytesIn: 2_000, bytesOut: 0)],
                    ssid: ssidPlaceholder, idle: false)
    let backHours = Aggregator(db: back, cal: london).hourly(day: london.parseLocal("2026-10-25T12:00")!,
                                                            now: london.parseLocal("2026-10-25T23:00")!)
    check(backHours[1].bytesIn == 3_000 && backHours[2].bytesIn == 0, "both 01:30s on the day the clocks go back are the 01:00 slot")
    // 29 Mar 2026: 01:00 to 01:59 never happens. 00:30 and 01:30 UTC are 00:30 GMT and 02:30 BST.
    let forward = makeDatabase()
    forward.addBuckets([BucketDelta(minute: 1_774_744_200 / 60, iface: "en0", bytesIn: 1_000, bytesOut: 0),
                        BucketDelta(minute: 1_774_747_800 / 60, iface: "en0", bytesIn: 2_000, bytesOut: 0)],
                       ssid: ssidPlaceholder, idle: false)
    let forwardHours = Aggregator(db: forward, cal: london).hourly(day: london.parseLocal("2026-03-29T12:00")!,
                                                                  now: london.parseLocal("2026-03-29T23:00")!)
    check(forwardHours[0].bytesIn == 1_000 && forwardHours[1].bytesIn == 0 && forwardHours[2].bytesIn == 2_000,
          "the hour skipped when the clocks go forward is empty, and 02:30 is the 02:00 slot")
}

// MARK: - Yesterday until now stays inside yesterday, across clock changes

func checkYesterdayUntilStaysInYesterday() {
    // The same time yesterday may not exist, or may have happened twice.
    for (zone, text) in [("Europe/London", "2026-10-26T01:30"), ("Europe/London", "2026-03-30T01:30"),
                         ("America/Santiago", "2026-09-07T00:30")] {
        let cal = BytemeterCalendar(timeZone: TimeZone(identifier: zone)!)
        let at = cal.parseLocal(text)!
        let range = cal.yesterdayUntil(at)
        let whole = cal.yesterday(at)
        check(range.start == whole.start && range.end > range.start && range.end <= whole.end,
              "\(zone) at \(text): yesterday until now stays inside yesterday, got \(range) in \(whole)")
    }
}
