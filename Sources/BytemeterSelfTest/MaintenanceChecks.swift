import Foundation
import BytemeterCore

// Checks for the daily tidy up, which collapses minute rows older than 90
// days into hourly ones: no byte lost, local hours kept in every time zone,
// and the estimated share carried through exactly.

// MARK: - Pruning collapses old minutes and loses no byte

func checkPruningLosesNoByte() {
    let db = makeDatabase()
    let now = Date()
    let oldMinute = BytemeterCalendar.minute(from: now) - 200 * 24 * 60
    var expected: UInt64 = 0
    for offset in 0..<120 {
        db.addBuckets([BucketDelta(minute: oldMinute + Int64(offset), iface: "en0",
                                   bytesIn: 1_000, bytesOut: 100)],
                      ssid: ssidPlaceholder, idle: false)
        expected += 1_000
    }
    // The window has to start on an hour boundary. Collapsing moves a row to
    // the start of its hour, which can be earlier than a window that begins
    // mid-hour, and the bytes would then sit just outside it. Every range the
    // app itself asks for starts at local midnight, which is always an hour
    // boundary here, so this only bites a hand written query like this one.
    let alignedStart = (oldMinute / 60) * 60 - 60
    let range = MinuteRange(start: alignedStart, end: oldMinute + 500)
    let everything = MinuteRange(start: 0, end: 9_999_999_999)
    let aggregator = Aggregator(db: db, cal: london)
    expect(aggregator.totals(range).bytesIn, expected, "totals before pruning")
    let collapsed = try! Maintenance.prune(db: db, now: now, timeZone: london.calendar.timeZone)
    check(collapsed > 0, "pruning found old minute buckets to collapse")
    expect(aggregator.totals(everything).bytesIn, expected, "pruning must not lose a single byte overall")
    expect(aggregator.totals(range).bytesIn, expected, "pruning must not change an hour aligned total")
    var rowCount: Int64 = 0
    try! db.query("SELECT COUNT(*) FROM samples WHERE minute>=? AND minute<?;",
                  [.int(range.start), .int(range.end)]) { rowCount = $0.int(0) }
    check(rowCount < 10, "120 minute buckets collapse into a couple of hourly rows, got \(rowCount)")
}

// MARK: - Pruning keeps the mark

func checkPruningKeepsTheMark() {
    let db = makeDatabase()
    let now = Date()
    let oldHour = ((BytemeterCalendar.minute(from: now) - 200 * 24 * 60) / 60) * 60
    for offset in 0..<60 {
        // The first old hour has one spread minute in it; the second has none.
        db.addBuckets([BucketDelta(minute: oldHour + Int64(offset), iface: "en0", bytesIn: 1_000, bytesOut: 100,
                                   estimated: offset == 30)], ssid: ssidPlaceholder, idle: false)
        db.addBuckets([BucketDelta(minute: oldHour + 60 + Int64(offset), iface: "en0", bytesIn: 1_000, bytesOut: 100)],
                      ssid: ssidPlaceholder, idle: false)
    }
    let everything = MinuteRange(start: 0, end: 9_999_999_999)
    let before = Aggregator(db: db, cal: london).totals(everything)
    check(try! Maintenance.prune(db: db, now: now, timeZone: london.calendar.timeZone) > 0, "pruning collapses the old hours")
    expect(estimatedFlag(db, minute: oldHour), 1, "an hour with any estimated minute stays estimated once collapsed")
    expect(estimatedFlag(db, minute: oldHour + 60), 0, "an hour of measured minutes stays measured once collapsed")
    let after = Aggregator(db: db, cal: london).totals(everything)
    expect(after.bytesIn, before.bytesIn, "pruning with the new column loses no byte")
    expect(after.estimatedIn, 1_000, "the collapsed hour reports only its spread minute's bytes as estimated")
}

// MARK: - Pruning keeps the estimated bytes exactly

func checkPruningKeepsEstimatedBytesExactly() {
    // One old hour: on en0 a single spread minute among 59 measured ones,
    // and on en1, on another network, measured minutes only.
    let db = makeDatabase()
    let now = london.parseLocal("2026-10-02T12:00")!
    let hour = BytemeterCalendar.minute(from: london.parseLocal("2026-05-02T10:00")!)
    for offset in Int64(0)..<60 {
        let spread = offset == 17
        db.addBuckets([BucketDelta(minute: hour + offset, iface: "en0", bytesIn: spread ? 7_777 : 1_000,
                                   bytesOut: spread ? 333 : 100, estimated: spread)], ssid: ssidPlaceholder, idle: false)
        db.addBuckets([BucketDelta(minute: hour + offset, iface: "en1", bytesIn: 2_000, bytesOut: 200)], ssid: "Cafe", idle: false)
    }
    let aggregator = Aggregator(db: db, cal: london)
    let range = MinuteRange(start: hour, end: hour + 60)
    let before = aggregator.totals(range)
    expect(before, Totals(bytesIn: 59_000 + 7_777 + 120_000, bytesOut: 5_900 + 333 + 12_000, estimatedIn: 7_777, estimatedOut: 333),
           "the hour before pruning holds one spread minute's bytes as estimated")
    expect(try! Maintenance.prune(db: db, now: now, timeZone: london.calendar.timeZone), 118,
           "pruning collapses every minute row but the two already on the hour")
    expect(aggregator.totals(range), before, "a pruned hour keeps exactly its spread minute's estimated bytes, and its total")
    expect(estimatedBytes(db, minute: hour), [7_777, 333], "on the collapsed row of the interface it was spread on")
    expect(estimatedBytes(db, minute: hour, iface: "en1"), [0, 0], "and none on the other interface's")
    expect(estimatedFlag(db, minute: hour), 1, "the collapsed row keeps its mark")

    let everyRow = "SELECT minute, bytes_in, bytes_out, idle, estimated, est_in, est_out FROM samples ORDER BY minute, iface, ssid;"
    let rowsAfter = rawRows(db.path, everyRow)
    expect(rowsAfter.count, 2, "one row is left for the hour on each interface and network")
    expect(try! Maintenance.prune(db: db, now: now, timeZone: london.calendar.timeZone), 0, "a second prune collapses nothing")
    expect(rawRows(db.path, everyRow), rowsAfter, "pruning twice changes nothing")
    expect(aggregator.totals(range), before, "and the hour reads as it did")
}

// MARK: - Pruning keeps local hours in every zone

func checkPruningKeepsLocalHoursInEveryZone() {
    // Twelve hours of minutes centred on local midnight; each clock change here falls between 01:00 and 03:00.
    let cases = [("Asia/Kolkata", "2026-06-01T00:00"), ("Asia/Kathmandu", "2026-06-01T00:00"),
                 ("America/St_Johns", "2026-03-08T00:00"), ("Australia/Adelaide", "2026-04-05T00:00"),
                 ("Australia/Lord_Howe", "2026-04-05T00:00"), ("Australia/Lord_Howe", "2026-10-04T00:00"),
                 ("Europe/London", "2026-03-29T00:00")]
    for (zone, around) in cases {
        let tz = TimeZone(identifier: zone)!
        let cal = BytemeterCalendar(timeZone: tz)
        let db = makeDatabase()
        let firstMinute = BytemeterCalendar.minute(from: cal.parseLocal(around)!) - 6 * 60 - 7
        var rows: [BucketDelta] = []
        for step in 0..<(12 * 60) {
            let offset = Int64(step)
            rows.append(BucketDelta(minute: firstMinute + offset, iface: "en0", bytesIn: 1_000 + UInt64(step), bytesOut: 1,
                                    estimated: step % 97 == 0))
        }
        db.addBuckets(rows, ssid: ssidPlaceholder, idle: false)
        db.addProcBuckets(minute: firstMinute + 400, deltas: ["Safari": (5_000, 50)])
        let before = localHourTotals(db, cal)
        let dayBefore = Aggregator(db: db, cal: cal).daily(lastDays: 3, now: cal.parseLocal(around)!.addingTimeInterval(86_400))
        let now = cal.parseLocal(around)!.addingTimeInterval(200 * 86_400)
        let collapsed = try! Maintenance.prune(db: db, now: now, timeZone: tz)
        check(collapsed > 600, "\(zone) around \(around): the old minutes are collapsed, got \(collapsed)")
        expect(localHourTotals(db, cal), before, "\(zone) around \(around): no byte moves into another local hour")
        let dayAfter = Aggregator(db: db, cal: cal).daily(lastDays: 3, now: cal.parseLocal(around)!.addingTimeInterval(86_400))
        // Estimated share included: a collapsed hour keeps exactly its minutes' estimated bytes.
        expect(dayAfter.map(\.totals), dayBefore.map(\.totals), "\(zone) around \(around): every day's figure is unchanged")
        var misplaced = 0
        try! db.query("SELECT minute FROM samples UNION SELECT minute FROM proc_samples;") { row in
            let date = BytemeterCalendar.date(fromMinute: row.int(0))
            let onTheHour = cal.calendar.component(.minute, from: date) == 0
            let onAChange = tz.secondsFromGMT(for: date) != tz.secondsFromGMT(for: date.addingTimeInterval(-60))
            if !onTheHour && !onAChange { misplaced += 1 }
        }
        expect(misplaced, 0, "\(zone) around \(around): every collapsed row is on a local hour, or on the clock change itself")
        expect(try! Maintenance.prune(db: db, now: now, timeZone: tz), 0, "\(zone) around \(around): a second prune finds nothing to do")
    }

    // A prune that fails records neither its event nor the tidy up as done, and the next check does the work.
    let db = makeDatabase()
    let now = london.parseLocal("2026-10-02T12:00")!
    let oldHour = BytemeterCalendar.minute(from: london.parseLocal("2026-03-02T10:00")!)
    db.addBuckets((1...60).map { BucketDelta(minute: oldHour + Int64($0), iface: "en0", bytesIn: 1_000, bytesOut: 10) },
                  ssid: ssidPlaceholder, idle: false)
    try! db.exec("CREATE TRIGGER fail_prune BEFORE INSERT ON samples BEGIN SELECT RAISE(ABORT, 'simulated failure'); END;")
    var threw = false
    do { _ = try Maintenance.runIfDue(db: db, now: now, timeZone: london.calendar.timeZone) } catch { threw = true }
    check(threw, "a prune that fails says so")
    func countRows(_ sql: String) -> Int64 { var n: Int64 = -1; try? db.query(sql) { n = $0.int(0) }; return n }
    expect(countRows("SELECT COUNT(*) FROM events WHERE kind='prune';"), 0, "and writes no prune event")
    expect(db.state(StateKey.lastMaintenance), nil, "and does not record the tidy up as done")
    expect(countRows("SELECT COUNT(*) FROM samples;"), 60, "and leaves every minute row where it was")
    try! db.exec("DROP TRIGGER fail_prune;")
    expect(try! Maintenance.runIfDue(db: db, now: now, timeZone: london.calendar.timeZone), 59, "the next check collapses them")
    expect(countRows("SELECT COUNT(*) FROM events WHERE kind='prune';"), 1, "writes its event")
    expect(db.state(StateKey.lastMaintenance), String(Int64(now.timeIntervalSince1970)), "and records the tidy up")
    expect(try! Maintenance.runIfDue(db: db, now: now.addingTimeInterval(3_600), timeZone: london.calendar.timeZone), nil,
           "after which it is not due again for a day")
}
