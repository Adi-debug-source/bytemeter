import Foundation
import SQLite3
import BytemeterCore

// A plain executable rather than XCTest: XCTest cannot be resolved with the
// Command Line Tools alone, and this must run without full Xcode. The checks below are the
// real ones, covering the counting rules that have to be right.

var checksRun = 0
var failures: [String] = []

func check(_ condition: Bool, _ message: String) {
    checksRun += 1
    if !condition { failures.append(message) }
}

func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    checksRun += 1
    if actual != expected { failures.append("\(message): expected \(expected), got \(actual)") }
}

func reading(_ name: String, _ bytesIn: UInt64, _ bytesOut: UInt64) -> InterfaceReading {
    InterfaceReading(name: name, bytesIn: bytesIn, bytesOut: bytesOut)
}

func makeDatabase() -> Database {
    let path = NSTemporaryDirectory() + "bytemeter_selftest_\(UUID().uuidString).db"
    return try! Database(path: path)
}

let london = BytemeterCalendar(timeZone: TimeZone(identifier: "Europe/London")!)

// MARK: - The ordinary case

do {
    let previous = ["en0": RawCounter(bytesIn: 1_000, bytesOut: 500, at: 600)]
    let outcome = Ledger.ingest(readings: [reading("en0", 4_000, 800)],
                                previous: previous, now: 605, source: .mib64, reason: .normal, bootTime: nil)
    expect(outcome.buckets.count, 1, "normal delta writes one bucket")
    expect(outcome.buckets.first?.bytesIn, 3_000, "normal delta down")
    expect(outcome.buckets.first?.bytesOut, 300, "normal delta up")
    expect(outcome.buckets.first?.minute, 10, "bucket lands in the current minute")
    expect(outcome.baselines["en0"]?.bytesIn, 4_000, "baseline moves forward")
}

// MARK: - First sight is a baseline, never traffic

do {
    let outcome = Ledger.ingest(readings: [reading("en0", 4_700_000_000, 85_000_000)],
                                previous: [:], now: 600, source: .mib64, reason: .relaunch, bootTime: nil)
    check(outcome.buckets.isEmpty, "first sight of an interface must record no traffic")
    expect(outcome.events.first?.kind, "baseline", "first sight logs a baseline event")
    expect(outcome.baselines["en0"]?.bytesIn, 4_700_000_000, "first sight sets the baseline")
}

// MARK: - A reboot must not become a phantom multi GB spike

do {
    let previous = ["en0": RawCounter(bytesIn: 4_700_000_000, bytesOut: 85_000_000, at: 600)]
    let outcome = Ledger.ingest(readings: [reading("en0", 12_000, 3_000)],
                                previous: previous, now: 900, source: .mib64, reason: .relaunch, bootTime: nil)
    check(outcome.buckets.isEmpty, "a counter reset must not write any traffic")
    expect(outcome.events.first?.kind, "counter_reset", "a reset is logged as an event")
    expect(outcome.baselines["en0"]?.bytesIn, 12_000, "a reset moves the baseline to the new value")
}

// MARK: - 32 bit wrap versus reboot

do {
    let nearCeiling: UInt64 = 4_294_967_296 - 1_000
    let previous = ["en0": RawCounter(bytesIn: nearCeiling, bytesOut: 10, at: 600)]
    let outcome = Ledger.ingest(readings: [reading("en0", 500, 20)],
                                previous: previous, now: 605, source: .ifdata32, reason: .normal, bootTime: nil)
    expect(outcome.buckets.count, 1, "a wrap still records traffic")
    expect(outcome.buckets.first?.bytesIn, 1_500, "wrap carries 1,000 to the ceiling plus 500 after it")
    expect(outcome.events.first?.kind, "counter_wrap", "a wrap is logged as a wrap")
}

do {
    let previous = ["en0": RawCounter(bytesIn: 500_000, bytesOut: 400, at: 600)]
    let outcome = Ledger.ingest(readings: [reading("en0", 100, 10)],
                                previous: previous, now: 605, source: .ifdata32, reason: .normal, bootTime: nil)
    check(outcome.buckets.isEmpty, "a fall far from the 32 bit ceiling is a reboot, not a wrap")
    expect(outcome.events.first?.kind, "counter_reset", "that case is logged as a reset")
}

// MARK: - Sleep gaps are spread, and nothing is lost to rounding

do {
    let previous = ["en0": RawCounter(bytesIn: 1_000, bytesOut: 100, at: 600)]   // minute 10
    let now: Int64 = 600 + 3_600                                                 // minute 70
    let outcome = Ledger.ingest(readings: [reading("en0", 1_000 + 100_003, 100 + 61)],
                                previous: previous, now: now, source: .mib64, reason: .sleep, bootTime: nil)
    expect(outcome.buckets.count, 60, "one bucket per elapsed minute")
    expect(outcome.buckets.first?.minute, 11, "spreading starts the minute after the last reading")
    expect(outcome.buckets.last?.minute, 70, "spreading ends at the current minute")
    let totalIn = outcome.buckets.reduce(UInt64(0)) { $0 + $1.bytesIn }
    let totalOut = outcome.buckets.reduce(UInt64(0)) { $0 + $1.bytesOut }
    expect(totalIn, 100_003, "spreading must not lose the remainder, down")
    expect(totalOut, 61, "spreading must not lose the remainder, up")
    expect(outcome.events.first?.kind, "gap_sleep", "a sleep gap is recorded honestly as a gap")
}

// MARK: - Traffic while Bytemeter was not running is recovered

do {
    let previous = ["en0": RawCounter(bytesIn: 1_000, bytesOut: 0, at: 600)]
    let outcome = Ledger.ingest(readings: [reading("en0", 601_000, 0)],
                                previous: previous, now: 600 + 600, source: .mib64, reason: .relaunch, bootTime: nil)
    let totalIn = outcome.buckets.reduce(UInt64(0)) { $0 + $1.bytesIn }
    expect(totalIn, 600_000, "a relaunch recovers the traffic from while it was down")
    expect(outcome.events.first?.kind, "gap_relaunch", "the downtime is logged")
}

// MARK: - Interface filtering

do {
    for name in ["en0", "en1", "en12"] {
        check(InterfaceMonitor.isPhysical(name), "\(name) should be counted")
    }
    for name in ["lo0", "utun0", "utun5", "awdl0", "llw0", "bridge0", "gif0", "stf0", "ap1", "anpi0", "nan0", "en"] {
        check(!InterfaceMonitor.isPhysical(name), "\(name) must not be counted")
    }
}

// MARK: - Units are decimal

do {
    expect(Units.bytes(999), "999 B", "bytes under a kB")
    expect(Units.bytes(1_000_000), "1.0 MB", "one MB is a million bytes")
    expect(Units.bytes(1_000_000_000), "1.00 GB", "one GB is a thousand million bytes")
    expect(Units.bytes(4_800_000_000), "4.80 GB", "GB with two decimals")
    expect(Units.bytes(4_800_000_000, compact: true), "4.8 GB", "compact GB for the menu bar")
    expect(Units.rate(2_100_000), "2.1 MB/s", "rate formatting")
}

// MARK: - Database behaviour

do {
    let db = makeDatabase()
    db.addBuckets([BucketDelta(minute: 100, iface: "en0", bytesIn: 500, bytesOut: 50)],
                  ssid: ssidPlaceholder, idle: true)
    db.addBuckets([BucketDelta(minute: 100, iface: "en0", bytesIn: 250, bytesOut: 25)],
                  ssid: ssidPlaceholder, idle: false)
    let aggregator = Aggregator(db: db, cal: london)
    let totals = aggregator.totals(MinuteRange(start: 0, end: 1_000))
    expect(totals.bytesIn, 750, "buckets accumulate on conflict, down")
    expect(totals.bytesOut, 75, "buckets accumulate on conflict, up")
    let split = aggregator.idleSplit(MinuteRange(start: 0, end: 1_000))
    expect(split.active.bytesIn, 750, "a minute with any activity counts as active")
    expect(split.idle.bytesIn, 0, "that minute is no longer counted as idle")
}

do {
    let db = makeDatabase()
    db.saveBaselines(["en0": RawCounter(bytesIn: 42, bytesOut: 7, at: 1_234)])
    expect(db.baselines()["en0"], RawCounter(bytesIn: 42, bytesOut: 7, at: 1_234), "baselines round trip")
}

do {
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
    let collapsed = Maintenance.prune(db: db, now: now)
    check(collapsed > 0, "pruning found old minute buckets to collapse")
    expect(aggregator.totals(everything).bytesIn, expected, "pruning must not lose a single byte overall")
    expect(aggregator.totals(range).bytesIn, expected, "pruning must not change an hour aligned total")
    var rowCount: Int64 = 0
    try! db.query("SELECT COUNT(*) FROM samples WHERE minute>=? AND minute<?;",
                  [.int(range.start), .int(range.end)]) { rowCount = $0.int(0) }
    check(rowCount < 10, "120 minute buckets collapse into a couple of hourly rows, got \(rowCount)")
}

do {
    var components = DateComponents()
    components.year = 2026; components.month = 9; components.day = 20; components.hour = 12
    let saturday = london.calendar.date(from: components)!
    let start = london.startOfWeek(saturday)
    expect(london.calendar.component(.weekday, from: start), 2, "the week starts on Monday")
    expect(london.calendar.component(.day, from: start), 14, "the Monday of the week containing Sun 20 Sep 2026 is the 14th")
}

do {
    let db = makeDatabase()
    db.addProcBuckets(minute: 50, deltas: ["Safari": (5_000, 100), "Backup": (9_000, 50)])
    let talkers = Aggregator(db: db, cal: london).topTalkers(MinuteRange(start: 0, end: 100), limit: 5)
    expect(talkers.first?.name, "Backup", "top talkers rank by total bytes")
    expect(talkers.count, 2, "both processes are listed")
}

// MARK: - Menu bar mode cycling

do {
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

// MARK: - Estimated rows: only spread minutes carry the mark

do {
    let measured = Ledger.ingest(readings: [reading("en0", 4_000, 800)],
                                 previous: ["en0": RawCounter(bytesIn: 1_000, bytesOut: 500, at: 600)],
                                 now: 605, source: .mib64, reason: .normal, bootTime: nil)
    check(measured.buckets.allSatisfy { !$0.estimated }, "a measured delta is not marked estimated")

    let previous = ["en0": RawCounter(bytesIn: 1_000, bytesOut: 100, at: 600)]
    let slept = Ledger.ingest(readings: [reading("en0", 1_000 + 100_003, 100 + 61)],
                              previous: previous, now: 600 + 3_600, source: .mib64, reason: .sleep, bootTime: nil)
    check(!slept.buckets.isEmpty && slept.buckets.allSatisfy(\.estimated), "every spread row is marked estimated")

    // The event the spread writes must lead back to exactly the minutes it filled.
    let window = slept.events.first.flatMap { Ledger.spreadWindow(eventTs: $0.ts, detail: $0.detail) }
    expect(window, SpreadWindow(iface: "en0", firstMinute: 11, lastMinute: 70),
           "a spread event reads back to the minutes it covered")
    expect(window?.firstMinute, slept.buckets.first?.minute, "the read back window starts at the first spread row")
    expect(window?.lastMinute, slept.buckets.last?.minute, "the read back window ends at the wake minute")
    expect(Ledger.spreadWindow(eventTs: 4_200, detail: "en0 gap of lots. Spread somehow."), nil,
           "an unreadable spread event gives no window rather than a guess")
    expect(Ledger.spreadWindow(eventTs: 4_200,
                               detail: "en0 gap of 3600 seconds. 5 in and 5 out spread evenly across 9 minutes."), nil,
           "a spread event whose minutes disagree with its own duration gives no window")

    let tooLong = Ledger.ingest(readings: [reading("en0", 2_000, 200)], previous: previous,
                                now: 600 + (Ledger.maxSpreadMinutes + 10) * 60, source: .mib64,
                                reason: .sleep, bootTime: nil)
    expect(tooLong.buckets.count, 1, "a gap too long to spread lands in one minute")
    check(tooLong.buckets.first?.estimated == true, "that minute is marked estimated: right bytes, wrong minute")
    expect(tooLong.events.first?.kind, "gap_too_long", "and it is logged as too long")
}

func estimatedFlag(_ db: Database, minute: Int64, iface: String = "en0") -> Int64 {
    var flag: Int64 = -1
    try? db.query("SELECT estimated FROM samples WHERE minute=? AND iface=?;",
                  [.int(minute), .text(iface)]) { flag = $0.int(0) }
    return flag
}

do {
    let db = makeDatabase()
    // The wake minute: the end of a spread, then bytes measured after waking.
    db.addBuckets([BucketDelta(minute: 200, iface: "en0", bytesIn: 100, bytesOut: 10, estimated: true)],
                  ssid: ssidPlaceholder, idle: true)
    db.addBuckets([BucketDelta(minute: 200, iface: "en0", bytesIn: 50, bytesOut: 5)],
                  ssid: ssidPlaceholder, idle: false)
    expect(estimatedFlag(db, minute: 200), 1, "a measured delta added later must not clear the estimated mark")
    // The other order, which the upsert must treat the same way.
    db.addBuckets([BucketDelta(minute: 300, iface: "en0", bytesIn: 50, bytesOut: 5)],
                  ssid: ssidPlaceholder, idle: false)
    db.addBuckets([BucketDelta(minute: 300, iface: "en0", bytesIn: 100, bytesOut: 10, estimated: true)],
                  ssid: ssidPlaceholder, idle: false)
    expect(estimatedFlag(db, minute: 300), 1, "an estimate added to a measured minute marks it")
    db.addBuckets([BucketDelta(minute: 400, iface: "en0", bytesIn: 1, bytesOut: 1)], ssid: ssidPlaceholder, idle: false)
    db.addBuckets([BucketDelta(minute: 400, iface: "en0", bytesIn: 1, bytesOut: 1)], ssid: ssidPlaceholder, idle: false)
    expect(estimatedFlag(db, minute: 400), 0, "two measured deltas leave a minute measured")

    let totals = Aggregator(db: db, cal: london).totals(MinuteRange(start: 0, end: 1_000))
    expect(totals.bytesIn, 302, "estimated bytes still count in the total")
    expect(totals.estimatedIn, 300, "a marked minute counts as estimated in full, wake minute included")
    expect(totals.estimatedOut, 30, "a marked minute counts as estimated in full, up")
}

// MARK: - The version 2 migration finds the old spread rows, and only them

/// Run raw SQL against a file, as the first release would have, without going
/// through `Database` and its migration.
func rawExec(_ path: String, _ sql: String) -> Bool {
    var handle: OpaquePointer?
    guard sqlite3_open(path, &handle) == SQLITE_OK else { return false }
    defer { sqlite3_close(handle) }
    return sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
}

func rawInt(_ path: String, _ sql: String) -> Int64 {
    var handle: OpaquePointer?
    var statement: OpaquePointer?
    guard sqlite3_open(path, &handle) == SQLITE_OK else { return -1 }
    defer { sqlite3_finalize(statement); sqlite3_close(handle) }
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW else { return -1 }
    return sqlite3_column_int64(statement, 0)
}

do {
    // A schema 1 database, exactly as the first release created it.
    let path = NSTemporaryDirectory() + "bytemeter_selftest_v1_\(UUID().uuidString).db"
    var sql = """
    CREATE TABLE samples(minute INTEGER NOT NULL, iface TEXT NOT NULL, ssid TEXT NOT NULL,
        bytes_in INTEGER NOT NULL DEFAULT 0, bytes_out INTEGER NOT NULL DEFAULT 0,
        idle INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(minute, iface, ssid));
    CREATE TABLE proc_samples(minute INTEGER NOT NULL, proc TEXT NOT NULL,
        bytes_in INTEGER NOT NULL DEFAULT 0, bytes_out INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(minute, proc));
    CREATE TABLE state(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE events(ts INTEGER NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '');
    CREATE INDEX idx_samples_minute ON samples(minute);
    CREATE INDEX idx_proc_minute ON proc_samples(minute);
    CREATE INDEX idx_events_ts ON events(ts);
    PRAGMA user_version=1;

    """

    // Fill it the way the old app did: real ingest outcomes, written with the
    // old upsert that had no estimated column. Two interfaces, a sleep, a
    // relaunch and a stall, with measured minutes either side of each gap,
    // including bytes measured into the wake minute after the spread.
    var expectedEstimated = Set<String>()
    var baselines: [String: RawCounter] = [:]
    var counters: [String: (UInt64, UInt64)] = ["en0": (4_700_000_000, 85_000_000), "en1": (3_000, 8_000)]
    var clock: Int64 = 600_000
    func step(_ seconds: Int64, _ reason: GapReason, en0: (UInt64, UInt64), en1: (UInt64, UInt64)) {
        clock += seconds
        counters["en0"] = (counters["en0"]!.0 + en0.0, counters["en0"]!.1 + en0.1)
        counters["en1"] = (counters["en1"]!.0 + en1.0, counters["en1"]!.1 + en1.1)
        let readings = counters.keys.sorted().map { reading($0, counters[$0]!.0, counters[$0]!.1) }
        let outcome = Ledger.ingest(readings: readings, previous: baselines, now: clock,
                                    source: .mib64, reason: reason, bootTime: nil)
        for (name, counter) in outcome.baselines { baselines[name] = counter }
        for bucket in outcome.buckets {
            if bucket.estimated { expectedEstimated.insert("\(bucket.minute)|\(bucket.iface)") }
            sql += """
            INSERT INTO samples(minute,iface,ssid,bytes_in,bytes_out,idle) VALUES(\(bucket.minute),'\(bucket.iface)','-',\(bucket.bytesIn),\(bucket.bytesOut),0)
            ON CONFLICT(minute,iface,ssid) DO UPDATE SET bytes_in=bytes_in+excluded.bytes_in, bytes_out=bytes_out+excluded.bytes_out;

            """
        }
        for event in outcome.events {
            sql += "INSERT INTO events(ts,kind,detail) VALUES(\(event.ts),'\(event.kind)','\(event.detail.replacingOccurrences(of: "'", with: "''"))');\n"
        }
    }
    step(0, .relaunch, en0: (0, 0), en1: (0, 0))                      // first sight: the lump, baseline only
    for _ in 0..<30 { step(5, .normal, en0: (40_000, 4_000), en1: (900, 90)) }
    step(7_200, .sleep, en0: (12_000_003, 2_000_001), en1: (7_777, 333))
    for _ in 0..<20 { step(5, .normal, en0: (50_000, 5_000), en1: (0, 0)) }   // into the wake minute
    step(1_800, .relaunch, en0: (3_000_000, 600_000), en1: (5, 1))   // en1: only the remainder row
    for _ in 0..<5 { step(5, .normal, en0: (1_000, 100), en1: (10, 1)) }
    step(200, .normal, en0: (400_000, 40_000), en1: (200, 20))         // a stall: gap_normal

    // Two events the backfill must refuse rather than guess at, and one it
    // must leave alone because it is a single minute, not a spread.
    sql += """
    INSERT INTO events(ts,kind,detail) VALUES(\(clock),'gap_sleep','en0 gap of lots. Spread somehow.');
    INSERT INTO events(ts,kind,detail) VALUES(\(clock),'gap_sleep','en0 gap of 3600 seconds. 5 in and 5 out spread evenly across 9 minutes.');
    INSERT INTO events(ts,kind,detail) VALUES(\(clock),'gap_too_long','en0 gap of 999999 seconds is longer than 10080 minutes. Recorded in one bucket rather than spread.');

    """
    check(rawExec(path, sql), "the schema 1 fixture builds")

    let rowsBefore = rawInt(path, "SELECT COUNT(*) FROM samples;")
    let inBefore = rawInt(path, "SELECT SUM(bytes_in) FROM samples;")
    let outBefore = rawInt(path, "SELECT SUM(bytes_out) FROM samples;")
    let spreadEvents = rawInt(path, "SELECT COUNT(*) FROM events WHERE kind IN ('gap_sleep','gap_relaunch','gap_normal');")
    expect(spreadEvents, 8, "the fixture holds six real spreads and two unreadable ones")

    let db = try! Database(path: path)                                 // runs the migration
    var marked = Set<String>()
    try! db.query("SELECT minute, iface FROM samples WHERE estimated=1;") { marked.insert("\($0.int(0))|\($0.string(1))") }
    check(!expectedEstimated.isEmpty, "the fixture has spread rows to find")
    expect(marked.count, expectedEstimated.count, "the backfill marks as many rows as were spread")
    check(marked == expectedEstimated, "the backfill marks exactly the spread rows, wake minutes included, and nothing else")

    expect(rawInt(path, "SELECT COUNT(*) FROM samples;"), rowsBefore, "the migration leaves the row count alone")
    expect(rawInt(path, "SELECT SUM(bytes_in) FROM samples;"), inBefore, "the migration leaves the download total alone")
    expect(rawInt(path, "SELECT SUM(bytes_out) FROM samples;"), outBefore, "the migration leaves the upload total alone")
    expect(rawInt(path, "PRAGMA user_version;"), 2, "the schema is now version 2")

    var detail = ""
    try! db.query("SELECT detail FROM events WHERE kind='estimated_backfill';") { detail = $0.string(0) }
    check(detail.hasPrefix("Marked \(expectedEstimated.count) minute rows as estimated, from 6 earlier gaps"),
          "the backfill event records the rows and the gaps, got: \(detail)")
    check(detail.contains("2 gap events could not be read"), "the backfill event counts what it skipped, got: \(detail)")

    // Opening it again must not run the backfill a second time.
    _ = try! Database(path: path)
    expect(rawInt(path, "SELECT COUNT(*) FROM events WHERE kind='estimated_backfill';"), 1, "the backfill runs once only")

    // A brand new database gets the column but no backfill event.
    let fresh = makeDatabase()
    var freshEvents: Int64 = -1
    try! fresh.query("SELECT COUNT(*) FROM events;") { freshEvents = $0.int(0) }
    expect(freshEvents, 0, "a new database has nothing to backfill and says nothing")
}

// MARK: - Pruning keeps the mark

do {
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
    check(Maintenance.prune(db: db, now: now) > 0, "pruning collapses the old hours")
    expect(estimatedFlag(db, minute: oldHour), 1, "an hour with any estimated minute stays estimated once collapsed")
    expect(estimatedFlag(db, minute: oldHour + 60), 0, "an hour of measured minutes stays measured once collapsed")
    let after = Aggregator(db: db, cal: london).totals(everything)
    expect(after.bytesIn, before.bytesIn, "pruning with the new column loses no byte")
    expect(after.estimatedIn, 60_000, "the collapsed hour reports its bytes as estimated")
}

// MARK: - The shaped views carry the estimated share

do {
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
    let heat = aggregator.heatmap(lastDays: 1, now: threeAM.addingTimeInterval(3_600))
    expect(heat.map(\.totals.estimatedIn).reduce(0, +), 900, "the heatmap knows which part was spread")
}

// MARK: - A restart books the bytes since boot; a bare interface reset does not

do {
    let previous = ["en0": RawCounter(bytesIn: 9_653_780_865, bytesOut: 858_256_858, at: 1_000_000)]

    let soon = Ledger.ingest(readings: [reading("en0", 9_071, 22_190)], previous: previous,
                             now: 1_000_537, source: .mib64, reason: .relaunch, bootTime: 1_000_500)
    expect(soon.buckets.count, 1, "a restart moments ago books its bytes in one minute")
    expect(soon.buckets.first?.bytesIn, 9_071, "everything since the restart is counted, down")
    expect(soon.buckets.first?.bytesOut, 22_190, "everything since the restart is counted, up")
    expect(soon.buckets.first?.minute, Ledger.floorDiv(1_000_537, 60), "in the current minute")
    check(soon.buckets.first?.estimated == false, "a restart within the threshold is not an estimate")
    expect(soon.events.first?.kind, "counter_reset", "the fall is still logged as a reset")
    check(soon.events.first?.detail.contains("restarted 37 seconds before") == true,
          "the event says it was a restart, got: \(soon.events.first?.detail ?? "")")
    expect(soon.baselines["en0"]?.bytesIn, 9_071, "the baseline moves to the new reading")

    let boot: Int64 = 1_000_500
    let later = Ledger.ingest(readings: [reading("en0", 6_000_007, 600_011)], previous: previous,
                              now: boot + 3_600, source: .mib64, reason: .relaunch, bootTime: boot)
    expect(later.buckets.first?.minute, Ledger.floorDiv(boot, 60), "a restart long ago spreads from the boot minute")
    expect(later.buckets.last?.minute, Ledger.floorDiv(boot + 3_600, 60), "to the current minute")
    expect(later.buckets.reduce(UInt64(0)) { $0 + $1.bytesIn }, 6_000_007, "the spread since boot loses nothing, down")
    expect(later.buckets.reduce(UInt64(0)) { $0 + $1.bytesOut }, 600_011, "the spread since boot loses nothing, up")
    check(later.buckets.allSatisfy(\.estimated), "bytes spread since a restart are marked estimated")
    check(later.events.first?.detail.contains("Spread evenly across 61 minutes from the restart") == true,
          "the event says how the restart was booked, got: \(later.events.first?.detail ?? "")")

    let interfaceOnly = Ledger.ingest(readings: [reading("en0", 9_071, 22_190)], previous: previous,
                                      now: 1_000_537, source: .mib64, reason: .normal, bootTime: 900_000)
    check(interfaceOnly.buckets.isEmpty, "an interface reset without a restart records nothing")
    check(interfaceOnly.events.first?.detail.contains("interface itself was reset") == true,
          "the event says it was the interface, got: \(interfaceOnly.events.first?.detail ?? "")")

    let unknown = Ledger.ingest(readings: [reading("en0", 9_071, 22_190)], previous: previous,
                                now: 1_000_537, source: .mib64, reason: .normal, bootTime: nil)
    check(unknown.buckets.isEmpty, "with no boot time a fall records nothing, as before")
    check(unknown.events.first?.detail.contains("could not be read") == true,
          "the event says the boot time was unreadable, got: \(unknown.events.first?.detail ?? "")")

    let future = Ledger.ingest(readings: [reading("en0", 9_071, 22_190)], previous: previous,
                               now: 1_000_537, source: .mib64, reason: .normal, bootTime: 2_000_000)
    check(future.buckets.isEmpty, "a boot time later than now is not trusted, so nothing is booked")

    let wrapPrevious = ["en0": RawCounter(bytesIn: 4_294_967_296 - 1_000, bytesOut: 10, at: 1_000_000)]
    let rebootNearCeiling = Ledger.ingest(readings: [reading("en0", 500, 20)], previous: wrapPrevious,
                                          now: 1_000_537, source: .ifdata32, reason: .normal, bootTime: 1_000_500)
    expect(rebootNearCeiling.buckets.first?.bytesIn, 500, "a known restart is never mistaken for a 32 bit wrap")

    let firstSight = Ledger.ingest(readings: [reading("en0", 4_700_000_000, 85_000_000)], previous: [:],
                                   now: 1_000_537, source: .mib64, reason: .relaunch, bootTime: 1_000_500)
    check(firstSight.buckets.isEmpty, "first sight stays baseline only, even with a boot time known")

    let booted = BootClock.bootTime()
    check(booted != nil, "this Mac's boot time can be read")
    check((booted ?? 0) > 0 && (booted ?? .max) <= Int64(Date().timeIntervalSince1970),
          "and it is in the past")
}

// MARK: - A restart is decided first, whether or not the counter fell

do {
    let previous = ["en0": RawCounter(bytesIn: 1_000_000, bytesOut: 100_000, at: 1_000_000)]
    let climbed = reading("en0", 5_000_000, 400_000)          // already past the old value

    let byBootTime = Ledger.ingest(readings: [climbed], previous: previous, now: 1_000_537,
                                   source: .mib64, reason: .relaunch, bootTime: 1_000_500)
    expect(byBootTime.buckets.first?.bytesIn, 5_000_000,
           "a restart where the counter has passed the old value books the full reading, not the difference")
    expect(byBootTime.buckets.first?.bytesOut, 400_000, "and the full reading up")
    check(byBootTime.events.first?.detail.contains("went from 1000000/100000 to 5000000/400000. The Mac restarted") == true,
          "the event says the counter went up across a restart, got: \(byBootTime.events.first?.detail ?? "")")

    let normal = Ledger.ingest(readings: [climbed], previous: previous, now: 1_000_005,
                               source: .mib64, reason: .normal, bootTime: 900_000)
    expect(normal.buckets.first?.bytesIn, 4_000_000, "a normal sample with the boot before the last reading takes the difference")
    check(normal.events.isEmpty, "and logs nothing")

    // With boot session ids on both sides, the id decides.
    let sessionA = ["en0": RawCounter(bytesIn: 1_000_000, bytesOut: 100_000, at: 1_000_000, bootSession: "A")]
    let newSession = Ledger.ingest(readings: [climbed], previous: sessionA, now: 1_000_537, source: .mib64,
                                   reason: .relaunch, bootTime: 1_000_500, bootSession: "B")
    expect(newSession.buckets.first?.bytesIn, 5_000_000, "a new boot session books the full reading")
    expect(newSession.baselines["en0"]?.bootSession, "B", "the new baseline carries the current boot session")

    // Setting the clock forward moves the kernel's boot time with it, past
    // the last reading. The session is unchanged, so it is not a restart, and
    // the traffic since boot must not be counted a second time.
    let clockSet = Ledger.ingest(readings: [climbed], previous: sessionA, now: 1_086_405, source: .mib64,
                                 reason: .normal, bootTime: 1_000_500, bootSession: "A")
    expect(clockSet.buckets.reduce(UInt64(0)) { $0 + $1.bytesIn }, 4_000_000,
           "a clock set forward is not a restart: only the difference is counted")
    check(!clockSet.events.contains { $0.kind == "counter_reset" }, "and no reset is logged")

    // Restarted by the id, but no usable boot time: placed across the whole gap.
    let unplaced = Ledger.ingest(readings: [climbed], previous: sessionA, now: 1_003_600, source: .mib64,
                                 reason: .normal, bootTime: nil, bootSession: "B")
    expect(unplaced.buckets.reduce(UInt64(0)) { $0 + $1.bytesIn }, 5_000_000,
           "a restart the boot time cannot place still books the full reading")
    check(unplaced.buckets.allSatisfy(\.estimated) && unplaced.buckets.first?.minute == Ledger.floorDiv(1_000_000, 60) + 1,
          "spread, as an estimate, from the minute after the last reading")
    check(unplaced.events.first?.detail.contains("could not say when") == true,
          "the event says the time was unknown, got: \(unplaced.events.first?.detail ?? "")")

    let fellSameSession = Ledger.ingest(readings: [reading("en0", 9_071, 22_190)], previous: sessionA,
                                        now: 1_000_537, source: .mib64, reason: .normal,
                                        bootTime: 1_000_500, bootSession: "A")
    check(fellSameSession.buckets.isEmpty, "a fall in the same boot session is an interface reset and books nothing")

    expect(RawCounter(encoded: "1,2,3,7DBE9237-C7FF"), RawCounter(bytesIn: 1, bytesOut: 2, at: 3, bootSession: "7DBE9237-C7FF"),
           "a baseline with a boot session reads back")
    expect(RawCounter(encoded: "1,2,3"), RawCounter(bytesIn: 1, bytesOut: 2, at: 3),
           "a baseline saved before sessions were kept still reads, with no session")
    expect(RawCounter(bytesIn: 1, bytesOut: 2, at: 3, bootSession: "X").encoded, "1,2,3,X", "the session is stored after the time")
    expect(RawCounter(encoded: "1,2"), nil, "a malformed baseline is refused")
    check(BootClock.bootSession() != nil, "this Mac's boot session id can be read")
}

// MARK: - All time is the sum of samples, without the first-seen lump

do {
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
                                    now: clock, source: .mib64, reason: .normal, bootTime: nil)
        db.addBuckets(outcome.buckets, ssid: ssidPlaceholder, idle: false)
        for (name, raw) in outcome.baselines { baselines[name] = raw }
        clock += 5
    }
    let aggregator = Aggregator(db: db, cal: london)
    let now = Date(timeIntervalSince1970: TimeInterval(clock + 86_400 * 3))
    let all = aggregator.allTime(now: now)
    var sumIn: Int64 = 0
    try! db.query("SELECT SUM(bytes_in) FROM samples;") { sumIn = $0.int(0) }
    expect(all.totals.bytesIn, UInt64(sumIn), "all time equals the sum of every sample")
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

do {
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
    expect(a.heatmap(lastDays: 30, now: asOf).map(\.totals), b.heatmap(lastDays: 30, now: asOf).map(\.totals), "the heatmap matches")
    expect(a.monthly(now: asOf).map(\.totals), b.monthly(now: asOf).map(\.totals), "month by month matches")
    let allA = a.allTime(now: asOf), allB = b.allTime(now: asOf)
    expect(allA.totals, allB.totals, "all time stops at the moment")
    check(allA.since == allB.since && allA.days == allB.days && allA.perDay == allB.perDay,
          "all time's start, day count and average match")
    check(a.allTime(now: asOf.addingTimeInterval(3 * 86_400)).totals.bytesIn > allA.totals.bytesIn,
          "and the later rows are really there to be left out")
    expect(a.projection(now: asOf).projected, b.projection(now: asOf).projected, "the projection matches")
    check(a.peakHourToday(now: asOf).map { [$0.hour] } == b.peakHourToday(now: asOf).map { [$0.hour] }
          && a.peakHourToday(now: asOf)?.totals == b.peakHourToday(now: asOf)?.totals, "the peak hour matches")
    check(a.peakDayThisCycle(now: asOf)?.totals == b.peakDayThisCycle(now: asOf)?.totals, "the peak day matches")
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
    expect(MenuModel.hint, "Right-click or two-finger click the figure to cycle today, week, month and all time.",
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

// MARK: - The demo opens its database strictly read only

do {
    let folder = NSTemporaryDirectory() + "bytemeter_selftest_demo_\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let path = folder + "/bytemeter.db"
    do {
        let db = try! Database(path: path)
        db.addBuckets([BucketDelta(minute: 29_832_080, iface: "en0", bytesIn: 4_000, bytesOut: 400)],
                      ssid: ssidPlaceholder, idle: false)
        var version: Int64 = -1
        try! db.query("PRAGMA user_version;") { version = $0.int(0) }
        expect(version, Database.schemaVersion, "a new database is at the version this build reads")
    }   // closed here, which folds the write-ahead log into the file

    func fingerprint() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.sorted() ?? []
        return names.map { name in
            let data = FileManager.default.contents(atPath: folder + "/" + name) ?? Data()
            return "\(name) \(data.count) \(data.hashValue)"
        }
    }
    let before = fingerprint()
    do {
        let reader = try Database(readOnlyPath: path)
        expect(Aggregator(db: reader, cal: london).totals(MinuteRange(start: 0, end: .max)).bytesIn, 4_000,
               "the read only database reads")
        var refused = false
        do { try reader.run("INSERT INTO events(ts,kind,detail) VALUES(1,'x','y');") } catch { refused = true }
        check(refused, "the read only database refuses a write")
        reader.setState("status_mode", "week")          // what Settings would try; must come to nothing
        expect(reader.state("status_mode"), nil, "a setting cannot be saved through it")
    } catch {
        check(false, "the read only database opens: \(error)")
    }
    expect(fingerprint(), before, "reading leaves every file in the folder exactly as it was, and adds none")

    // A database from before version 2 is refused, not read wrongly or upgraded.
    let oldPath = NSTemporaryDirectory() + "bytemeter_selftest_v1ro_\(UUID().uuidString).db"
    _ = rawExec(oldPath, "CREATE TABLE samples(minute INTEGER); PRAGMA user_version=1;")
    var oldRefused = false
    do { _ = try Database(readOnlyPath: oldPath) } catch { oldRefused = "\(error)".contains("schema version 1") }
    check(oldRefused, "a version 1 database is refused with the reason")
    expect(rawInt(oldPath, "PRAGMA user_version;"), 1, "and is left at version 1")

    // A write-ahead log that still holds changes is refused, because immutable mode would not see them.
    FileManager.default.createFile(atPath: path + "-wal", contents: Data(repeating: 1, count: 32))
    var walRefused = false
    do { _ = try Database(readOnlyPath: path) } catch { walRefused = "\(error)".contains("write-ahead log") }
    check(walRefused, "unsaved changes in the write-ahead log are refused, not ignored")
    var missingRefused = false
    do { _ = try Database(readOnlyPath: folder + "/nothing.db") } catch { missingRefused = true }
    check(missingRefused, "a missing database is refused rather than created")
    check(!FileManager.default.fileExists(atPath: folder + "/nothing.db"), "and nothing is created in its place")
}

// MARK: - Result

print("Bytemeter self-test: \(checksRun) checks run, \(failures.count) failed.")
for failure in failures { print("  FAILED: \(failure)") }
exit(failures.isEmpty ? 0 : 1)
