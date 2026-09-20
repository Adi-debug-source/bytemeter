import Foundation
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
                                previous: previous, now: 605, source: .mib64, reason: .normal)
    expect(outcome.buckets.count, 1, "normal delta writes one bucket")
    expect(outcome.buckets.first?.bytesIn, 3_000, "normal delta down")
    expect(outcome.buckets.first?.bytesOut, 300, "normal delta up")
    expect(outcome.buckets.first?.minute, 10, "bucket lands in the current minute")
    expect(outcome.baselines["en0"]?.bytesIn, 4_000, "baseline moves forward")
}

// MARK: - First sight is a baseline, never traffic

do {
    let outcome = Ledger.ingest(readings: [reading("en0", 4_700_000_000, 85_000_000)],
                                previous: [:], now: 600, source: .mib64, reason: .relaunch)
    check(outcome.buckets.isEmpty, "first sight of an interface must record no traffic")
    expect(outcome.events.first?.kind, "baseline", "first sight logs a baseline event")
    expect(outcome.baselines["en0"]?.bytesIn, 4_700_000_000, "first sight sets the baseline")
}

// MARK: - A reboot must not become a phantom multi GB spike

do {
    let previous = ["en0": RawCounter(bytesIn: 4_700_000_000, bytesOut: 85_000_000, at: 600)]
    let outcome = Ledger.ingest(readings: [reading("en0", 12_000, 3_000)],
                                previous: previous, now: 900, source: .mib64, reason: .relaunch)
    check(outcome.buckets.isEmpty, "a counter reset must not write any traffic")
    expect(outcome.events.first?.kind, "counter_reset", "a reset is logged as an event")
    expect(outcome.baselines["en0"]?.bytesIn, 12_000, "a reset moves the baseline to the new value")
}

// MARK: - 32 bit wrap versus reboot

do {
    let nearCeiling: UInt64 = 4_294_967_296 - 1_000
    let previous = ["en0": RawCounter(bytesIn: nearCeiling, bytesOut: 10, at: 600)]
    let outcome = Ledger.ingest(readings: [reading("en0", 500, 20)],
                                previous: previous, now: 605, source: .ifdata32, reason: .normal)
    expect(outcome.buckets.count, 1, "a wrap still records traffic")
    expect(outcome.buckets.first?.bytesIn, 1_500, "wrap carries 1,000 to the ceiling plus 500 after it")
    expect(outcome.events.first?.kind, "counter_wrap", "a wrap is logged as a wrap")
}

do {
    let previous = ["en0": RawCounter(bytesIn: 500_000, bytesOut: 400, at: 600)]
    let outcome = Ledger.ingest(readings: [reading("en0", 100, 10)],
                                previous: previous, now: 605, source: .ifdata32, reason: .normal)
    check(outcome.buckets.isEmpty, "a fall far from the 32 bit ceiling is a reboot, not a wrap")
    expect(outcome.events.first?.kind, "counter_reset", "that case is logged as a reset")
}

// MARK: - Sleep gaps are spread, and nothing is lost to rounding

do {
    let previous = ["en0": RawCounter(bytesIn: 1_000, bytesOut: 100, at: 600)]   // minute 10
    let now: Int64 = 600 + 3_600                                                 // minute 70
    let outcome = Ledger.ingest(readings: [reading("en0", 1_000 + 100_003, 100 + 61)],
                                previous: previous, now: now, source: .mib64, reason: .sleep)
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
                                previous: previous, now: 600 + 600, source: .mib64, reason: .relaunch)
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
    expect(StatusMode.month.next, StatusMode.today, "clicking this month comes back to today")
    expect(StatusMode(rawValue: "month"), StatusMode.month, "the saved mode round trips")
    expect(StatusMode.today.label, "Today", "labels are the ones shown in the menu")
}

// MARK: - Result

print("Bytemeter self-test: \(checksRun) checks run, \(failures.count) failed.")
for failure in failures { print("  FAILED: \(failure)") }
exit(failures.isEmpty ? 0 : 1)
