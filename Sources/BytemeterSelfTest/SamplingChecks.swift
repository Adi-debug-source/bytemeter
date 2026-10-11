import Foundation
import BytemeterCore

// Checks for what the sampler does around a reading: the reading taken
// before sleep, per-app deltas from nettop, the minute per-app rows are
// filed in, and the one write that records a reading, idle included.

// MARK: - The reading before sleep, and the label after it

func checkReadingBeforeSleep() {
    let gate = SleepGate()
    var log: [String] = []
    func sample() {
        if let reason = gate.reasonForReading { log.append(reason.rawValue); gate.readingWritten() } else { log.append("skipped") }
    }
    sample()                       // the first reading after launch
    sample()                       // the timer
    gate.enterSleep { sample() }   // the reading before sleep
    sample()                       // a timer firing while asleep
    gate.wake { sample() }         // the first reading after waking
    sample()                       // the timer
    expect(log, ["relaunch", "normal", "normal", "skipped", "sleep", "normal"],
           "the reading before sleep is taken, none while asleep, and the gap after waking is labelled sleep")

    let failing = SleepGate()
    failing.enterSleep { }
    var reasons: [GapReason?] = []
    failing.wake { reasons.append(failing.reasonForReading) }   // its write fails, so readingWritten is not called
    reasons.append(failing.reasonForReading)
    failing.readingWritten()
    reasons.append(failing.reasonForReading)
    expect(reasons, [.sleep, .sleep, .normal], "a wake reading whose write failed passes the sleep label on")

    let unannounced = SleepGate()
    unannounced.readingWritten()
    var firstAfterWake: GapReason?
    unannounced.wake { firstAfterWake = unannounced.reasonForReading }
    expect(firstAfterWake, .sleep, "a wake with no sleep notice before it still labels the gap as sleep")

    // Through the ledger: 30 kB in the last 4 seconds before sleep, then an hour asleep.
    let ledgerGate = SleepGate()
    var baselines: [String: RawCounter] = [:]
    var counter: UInt64 = 1_000_000
    var clock: Int64 = 1_790_000_000
    var buckets: [BucketDelta] = []
    var events: [LedgerEvent] = []
    func take() {
        guard let reason = ledgerGate.reasonForReading else { return }
        let outcome = Ledger.ingest(readings: [reading("en0", counter, counter)], previous: baselines, now: clock,
                                    reason: reason, bootTime: nil, bootSession: "A")
        buckets += outcome.buckets
        events += outcome.events
        for (name, raw) in outcome.baselines { baselines[name] = raw }
        ledgerGate.readingWritten()
    }
    take()
    clock += 5; counter += 40_000; take()
    clock += 4; counter += 30_000
    ledgerGate.enterSleep { take() }
    clock += 3_600; counter += 600_000
    take()                                     // a dark wake: skipped
    ledgerGate.wake { take() }
    expect(events.map(\.kind), ["baseline", "gap_sleep"], "the gap after waking is logged as gap_sleep")
    expect(buckets.filter { !$0.estimated }.reduce(UInt64(0)) { $0 + $1.bytesIn }, 70_000,
           "traffic up to the moment of sleep is measured, not spread across the sleep")
    expect(buckets.reduce(UInt64(0)) { $0 + $1.bytesIn }, 670_000, "and every byte is counted")
}

// MARK: - Per-app deltas from nettop's totals

/// A tally's result in a form `expect` can compare.
private func flat(_ deltas: [String: (bytesIn: UInt64, bytesOut: UInt64)]) -> [String: [UInt64]] {
    deltas.mapValues { [$0.bytesIn, $0.bytesOut] }
}

func checkProcessTallyDeltas() {
    // nettop's own shape: a header with an empty first field, then "name.pid,in,out," per process.
    let output = """
    ,bytes_in,bytes_out,
    Example Helper.512,1000,200,
    com.example.agent.77,5000,50,
    Spaced.9, 300 , 30,
    not a row
    Broken.10,lots,5,
    ,4,4,
    Short.11,7
    """
    expect(flat(ProcessTally.parse(output)),
           ["Example Helper.512": [1_000, 200], "com.example.agent.77": [5_000, 50], "Spaced.9": [300, 30]],
           "parse keeps every process row, names with dots included, and skips the header and malformed lines")
    expect(flat(ProcessTally.parse("")), [:], "an empty run parses to nothing")

    var tally = ProcessTally()
    expect(flat(tally.deltas(["Example Helper.512": (1_000, 200), "Mail.40": (9_000, 900)])), [:],
           "first sight of a process returns nothing")
    expect(flat(tally.deltas(["Example Helper.512": (1_500, 260), "Mail.40": (9_000, 900)])), ["Example Helper": [500, 60]],
           "a rise returns the difference by display name, and a process that did nothing is left out")
    expect(flat(tally.deltas(["Example Helper.512": (100, 10), "Mail.40": (9_000, 900)])), [:],
           "a fall, a reused pid, returns nothing")
    expect(flat(tally.deltas(["Example Helper.512": (400, 30), "Mail.40": (9_000, 900)])), ["Example Helper": [300, 20]],
           "and re-baselines, so the next rise counts from the lower total")
    expect(flat(tally.deltas([:])), [:], "an empty run returns nothing")
    expect(flat(tally.deltas(["Example Helper.512": (450, 30), "Mail.40": (9_000, 900)])), ["Example Helper": [50, 0]],
           "and leaves the previous totals as they were")

    var pair = ProcessTally()
    _ = pair.deltas(["Helper.10": (100, 10), "Helper.11": (200, 20), "com.example.agent.7": (5, 5), "Build.v2": (1, 1)])
    expect(flat(pair.deltas(["Helper.10": (150, 15), "Helper.11": (260, 26), "com.example.agent.7": (10, 5), "Build.v2": (2, 1)])),
           ["Helper": [110, 11], "com.example.agent": [5, 0], "Build.v2": [1, 0]],
           "two pids of one name add up, a dotted name loses only its pid, and a tail that is not all digits stays")

    // Per-app sampling switched off, then on again: the time it was off must not land in one minute.
    var paused = ProcessTally()
    _ = paused.deltas(["Backup.300": (1_000, 1_000)])
    paused.forget()
    expect(flat(paused.deltas(["Backup.300": (900_000_000, 50_000_000)])), [:],
           "after forget, the next call only baselines, however far the totals rose")
    expect(flat(paused.deltas(["Backup.300": (900_001_000, 50_000_000)])), ["Backup": [1_000, 0]],
           "and the call after that counts from there")
}

// MARK: - Per-app rows are filed no earlier than the last reading

func checkPerAppRowsAreHeld() {
    let lastMinute = Ledger.floorDiv(1_790_000_030, 60)
    let baselines = ["en0": RawCounter(bytesIn: 0, bytesOut: 0, at: 1_790_000_030, bootSession: "A", source: .mib64),
                     "en1": RawCounter(bytesIn: 0, bytesOut: 0, at: 1_789_000_000, bootSession: "A", source: .mib64)]
    expect(Ledger.heldMinute(Ledger.floorDiv(978_307_200, 60), baselines: baselines), lastMinute,
           "with the clock behind, per-app rows are held at the newest baseline's minute")
    expect(Ledger.heldMinute(lastMinute + 3, baselines: baselines), lastMinute + 3,
           "with the clock right, they are filed at the clock's minute")
    expect(Ledger.heldMinute(lastMinute, baselines: baselines), lastMinute, "and in the baseline's own minute, at it")
    expect(Ledger.heldMinute(29_832_080, baselines: [:]), 29_832_080, "with no baselines, at the clock's minute")

    // The hold matches the one the interface buckets get from Ledger.ingest under the same clock.
    let behind = Ledger.ingest(readings: [reading("en0", 5_000, 500)], previous: baselines, now: 978_307_200,
                               reason: .normal, bootTime: nil, bootSession: "A")
    expect(Ledger.heldMinute(Ledger.floorDiv(978_307_200, 60), baselines: behind.baselines), behind.buckets.first?.minute,
           "and is the minute the interface rows of that reading were booked in")
}

// MARK: - One write for one reading, and a sleep's spread minutes are idle

private func idleFlag(_ db: Database, minute: Int64, iface: String = "en0") -> Int64 {
    var flag: Int64 = -1
    try? db.query("SELECT idle FROM samples WHERE minute=? AND iface=?;", [.int(minute), .text(iface)]) { flag = $0.int(0) }
    return flag
}

func checkSleepSpreadIsIdle() {
    // An hour asleep, then the first reading after waking, taken while someone is at the keyboard.
    let slept: Int64 = 1_790_000_000
    let woke = slept + 3_600
    let before = ["en0": RawCounter(bytesIn: 1_000, bytesOut: 100, at: slept, bootSession: "A", source: .mib64)]
    let wakeMinute = Ledger.floorDiv(woke, 60)
    let spreadMinutes = Array((Ledger.floorDiv(slept, 60) + 1)...wakeMinute)

    let db = makeDatabase()
    db.saveBaselines(before)
    let wake = Ledger.ingest(readings: [reading("en0", 1_000 + 600_000, 100 + 60_000)], previous: before, now: woke,
                             reason: .sleep, bootTime: nil, bootSession: "A")
    expect(wake.buckets.map(\.minute), spreadMinutes, "the hour asleep is spread over its minutes")
    check(db.transaction { try db.writeReading(wake, ssid: ssidPlaceholder, idle: false, reason: .sleep, counterSource: .mib64) },
          "the wake reading is written")
    expect(spreadMinutes.map { idleFlag(db, minute: $0) }, Array(repeating: 1, count: spreadMinutes.count),
           "a sleep's spread minutes are written idle, though the wake moment was not")
    expect(db.baselines()["en0"], wake.baselines["en0"], "the reading's baseline is written with it")
    var gapEvents: Int64 = 0
    try! db.query("SELECT COUNT(*) FROM events WHERE kind='gap_sleep';") { gapEvents = $0.int(0) }
    expect(gapEvents, 1, "and so is its event")

    let after = Ledger.ingest(readings: [reading("en0", 1_000 + 600_000 + 5_000, 100 + 60_000 + 500)],
                              previous: db.baselines(), now: woke + 3, reason: .normal, bootTime: nil, bootSession: "A")
    expect(after.buckets.map(\.minute), [wakeMinute], "the next reading lands in the wake minute")
    check(db.transaction { try db.writeReading(after, ssid: ssidPlaceholder, idle: false, reason: .normal, counterSource: .mib64) },
          "the next reading is written")
    expect(idleFlag(db, minute: wakeMinute), 0, "someone at the keyboard after waking makes the wake minute active")
    expect(spreadMinutes.dropLast().map { idleFlag(db, minute: $0) }, Array(repeating: 1, count: spreadMinutes.count - 1),
           "and leaves the minutes asleep idle")
    let split = Aggregator(db: db, cal: london).idleSplit(MinuteRange(start: spreadMinutes[0], end: wakeMinute + 1))
    expect(split.idle.bytesIn, 590_000, "so the idle split books 59 minutes of the night as idle")
    expect(split.active.bytesIn, 15_000, "and only the wake minute as active")

    // The same gap after Bytemeter was not running: nobody knows whether anyone was there, so it takes the flag.
    let relaunched = makeDatabase()
    let back = Ledger.ingest(readings: [reading("en0", 1_000 + 600_000, 100 + 60_000)], previous: before, now: woke,
                             reason: .relaunch, bootTime: nil, bootSession: "A")
    check(relaunched.transaction {
        try relaunched.writeReading(back, ssid: ssidPlaceholder, idle: false, reason: .relaunch, counterSource: .mib64)
    }, "the reading after a relaunch is written")
    expect(spreadMinutes.map { idleFlag(relaunched, minute: $0) }, Array(repeating: 0, count: spreadMinutes.count),
           "a relaunch's spread minutes take the reading's flag")

    // A sleep too short to spread is measured, and measured buckets always take the flag.
    let napped = makeDatabase()
    let short = Ledger.ingest(readings: [reading("en0", 2_000, 200)], previous: before, now: slept + 60,
                              reason: .sleep, bootTime: nil, bootSession: "A")
    check(short.buckets.count == 1 && short.buckets.allSatisfy { !$0.estimated }, "a minute's sleep is measured, not spread")
    check(napped.transaction { try napped.writeReading(short, ssid: ssidPlaceholder, idle: false, reason: .sleep, counterSource: nil) },
          "and is written")
    expect(idleFlag(napped, minute: Ledger.floorDiv(slept + 60, 60)), 0, "a measured bucket after a sleep takes the reading's flag")
}

// MARK: - writeReading writes the counter source only when given one, and a failed write moves nothing

func checkWriteReadingCounterSourceAndRollback() {
    // The counter source is written when given, and left alone when not.
    let db = makeDatabase()
    let first = Ledger.ingest(readings: [reading32("en0", 1_000, 100)], previous: [:], now: 1_790_000_000,
                              reason: .relaunch, bootTime: nil, bootSession: "A")
    check(db.transaction { try db.writeReading(first, ssid: ssidPlaceholder, idle: false, reason: .relaunch, counterSource: .ifdata32) },
          "a first reading is written")
    expect(db.state(StateKey.counterSource), CounterSource.ifdata32.rawValue, "writeReading writes the counter source it is given")
    let next = Ledger.ingest(readings: [reading32("en0", 2_000, 200)], previous: db.baselines(), now: 1_790_000_005,
                             reason: .normal, bootTime: nil, bootSession: "A")
    check(db.transaction { try db.writeReading(next, ssid: ssidPlaceholder, idle: false, reason: .normal, counterSource: nil) },
          "a reading with no counter source is written")
    expect(db.state(StateKey.counterSource), CounterSource.ifdata32.rawValue, "and leaves the saved counter source alone")
    expect(sumIn(db), 1_000, "while its bytes are booked")

    // A failed bucket write moves nothing: not the baseline, not the events, not the counter source.
    db.log = { _ in }
    var eventsBefore: Int64 = 0
    try! db.query("SELECT COUNT(*) FROM events;") { eventsBefore = $0.int(0) }
    try! db.exec("CREATE TRIGGER fail_samples BEFORE INSERT ON samples BEGIN SELECT RAISE(ABORT, 'simulated failure'); END;")
    let failing = Ledger.ingest(readings: [reading32("en0", 9_000, 900), reading("en1", 50, 5)], previous: db.baselines(),
                                now: 1_790_000_010, reason: .normal, bootTime: nil, bootSession: "A")
    check(!failing.buckets.isEmpty && !failing.events.isEmpty, "the failing reading has buckets and an event to lose")
    check(!db.transaction { try db.writeReading(failing, ssid: ssidPlaceholder, idle: false, reason: .normal, counterSource: .mib64) },
          "a reading whose bucket write fails is not written")
    var eventsAfter: Int64 = 0
    try! db.query("SELECT COUNT(*) FROM events;") { eventsAfter = $0.int(0) }
    expect(db.baselines()["en0"]?.bytesIn, 2_000, "its baseline stays where it was")
    expect(db.baselines()["en1"], nil, "a new interface in it is not baselined")
    expect(eventsAfter, eventsBefore, "its events are not written")
    expect(db.state(StateKey.counterSource), CounterSource.ifdata32.rawValue, "and neither is its counter source")
}
