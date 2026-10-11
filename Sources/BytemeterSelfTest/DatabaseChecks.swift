import Foundation
import BytemeterCore

// Checks for how the database writes and reads: rows that add up on
// conflict, baselines, the estimated mark and bytes, transactions that fail
// or are ended by SQLite, a full disk, recent events, and the read only open
// the demo uses.

// MARK: - Buckets add up on conflict, and any activity makes a minute active

func checkBucketsAddUpOnConflict() {
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

// MARK: - Baselines round trip

func checkBaselinesRoundTrip() {
    let db = makeDatabase()
    db.saveBaselines(["en0": RawCounter(bytesIn: 42, bytesOut: 7, at: 1_234)])
    expect(db.baselines()["en0"], RawCounter(bytesIn: 42, bytesOut: 7, at: 1_234), "baselines round trip")
}

// MARK: - A measured delta never clears the estimated mark

func checkMeasuredBytesNeverClearTheMark() {
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
    expect(totals.estimatedIn, 200, "only the estimated bytes count as estimated, not those measured into the same minute")
    expect(totals.estimatedOut, 20, "only the estimated bytes count as estimated, up")
}

// MARK: - A minute keeps exactly its estimated bytes

func checkMinuteKeepsItsEstimatedBytes() {
    // An hour asleep, then a reading measured into the wake minute, as the sampler writes them.
    let slept: Int64 = 1_790_000_000
    let woke = slept + 3_600
    let before = ["en0": RawCounter(bytesIn: 1_000, bytesOut: 100, at: slept, bootSession: "A", source: .mib64)]
    let db = makeDatabase()
    let wake = Ledger.ingest(readings: [reading("en0", 1_000 + 600_000, 100 + 60_000)], previous: before, now: woke,
                             reason: .sleep, bootTime: nil, bootSession: "A")
    check(wake.buckets.count == 60 && wake.buckets.allSatisfy(\.estimated), "the hour asleep is spread over 60 minutes")
    check(db.transaction { try db.writeReading(wake, ssid: ssidPlaceholder, idle: false, reason: .sleep, counterSource: nil) },
          "the wake reading is written")
    let after = Ledger.ingest(readings: [reading("en0", 1_000 + 600_000 + 5_000, 100 + 60_000 + 500)],
                              previous: db.baselines(), now: woke + 3, reason: .normal, bootTime: nil, bootSession: "A")
    let spread = wake.buckets.last!
    expect(after.buckets.map(\.minute), [spread.minute], "the next reading lands in the wake minute")
    check(db.transaction { try db.writeReading(after, ssid: ssidPlaceholder, idle: false, reason: .normal, counterSource: nil) },
          "the next reading is written")

    expect(wake.buckets.dropLast().map { estimatedBytes(db, minute: $0.minute) },
           wake.buckets.dropLast().map { [Int64($0.bytesIn), Int64($0.bytesOut)] },
           "each minute asleep keeps its spread bytes as estimated")
    expect(estimatedBytes(db, minute: spread.minute), [Int64(spread.bytesIn), Int64(spread.bytesOut)],
           "the wake minute keeps only its spread bytes as estimated, not those measured after waking")
    expect(estimatedFlag(db, minute: spread.minute), 1, "and keeps its mark")
    var sums: [Int64] = []
    try! db.query("SELECT SUM(bytes_in), SUM(est_in), SUM(bytes_out), SUM(est_out) FROM samples;") {
        sums = [$0.int(0), $0.int(1), $0.int(2), $0.int(3)]
    }
    expect(sums, [605_000, 600_000, 60_500, 60_000], "every byte is counted, and only the spread ones are estimated")
    let aggregator = Aggregator(db: db, cal: london)
    expect(aggregator.minuteRows(MinuteRange(start: spread.minute, end: spread.minute + 1)).map {
               [$0.bytesIn, $0.estimatedIn, $0.bytesOut, $0.estimatedOut]
           }, [[spread.bytesIn + 5_000, spread.bytesIn, spread.bytesOut + 500, spread.bytesOut]],
           "the wake minute reports only its spread bytes as estimated")
    expect(aggregator.totals(MinuteRange(start: wake.buckets[0].minute, end: spread.minute + 1)),
           Totals(bytesIn: 605_000, bytesOut: 60_500, estimatedIn: 600_000, estimatedOut: 60_000),
           "and so does the hour asleep with it")

    // Two estimates in one minute add up, and measured bytes add nothing to them.
    db.addBuckets([BucketDelta(minute: 900, iface: "en0", bytesIn: 70, bytesOut: 7, estimated: true)],
                  ssid: ssidPlaceholder, idle: false)
    db.addBuckets([BucketDelta(minute: 900, iface: "en0", bytesIn: 30, bytesOut: 3, estimated: true)],
                  ssid: ssidPlaceholder, idle: false)
    expect(estimatedBytes(db, minute: 900), [100, 10], "two estimates in one minute add up")
    db.addBuckets([BucketDelta(minute: 901, iface: "en0", bytesIn: 40, bytesOut: 4)], ssid: ssidPlaceholder, idle: false)
    db.addBuckets([BucketDelta(minute: 901, iface: "en0", bytesIn: 40, bytesOut: 4)], ssid: ssidPlaceholder, idle: false)
    expect(estimatedBytes(db, minute: 901), [0, 0], "a measured minute has no estimated bytes")
}

// MARK: - A failed write moves nothing

func checkFailedWriteMovesNothing() {
    // A write that fails part way through a sample, here by a trigger.
    let db = makeDatabase()
    var logged: [String] = []
    db.log = { logged.append($0) }
    check(writeSample(db, raw: 1_000, at: 1_790_000_000), "first sight writes its baseline")
    try! db.exec("CREATE TRIGGER fail_samples BEFORE INSERT ON samples BEGIN SELECT RAISE(ABORT, 'simulated failure'); END;")
    check(!writeSample(db, raw: 51_000, at: 1_790_000_005), "a sample whose bucket write fails reports failure")
    expect(db.baselines()["en0"]?.bytesIn, 1_000, "and leaves the baseline where it was")
    for step in 1...5 { _ = writeSample(db, raw: 51_000 + UInt64(step) * 100, at: 1_790_000_005 + Int64(step) * 5) }
    expect(logged.count, 1, "six failures in a row are logged once, not every 5 seconds")
    expect(db.failedTransactionsInARow, 6, "but every one is counted")
    try! db.exec("DROP TRIGGER fail_samples;")
    check(writeSample(db, raw: 52_000, at: 1_790_000_040), "once writes work again the sample commits")
    expect(sumIn(db), 51_000, "and every byte since the last written baseline is recovered")
    expect(logged.count, 2, "the recovery is logged once too")
    check(logged.last?.contains("after 6 failed attempts") == true, "saying how many failed, got: \(logged.last ?? "")")

    // The forgiving forms, errors swallowed, still cannot commit a transaction without their rows.
    let forgiving = makeDatabase()
    forgiving.log = { _ in }
    forgiving.saveBaselines(["en0": RawCounter(bytesIn: 1_000, bytesOut: 100, at: 1_790_000_000, bootSession: "A", source: .mib64)])
    try! forgiving.exec("CREATE TRIGGER fail_samples BEFORE INSERT ON samples BEGIN SELECT RAISE(ABORT, 'simulated failure'); END;")
    let outcome = Ledger.ingest(readings: [reading("en0", 51_000, 5_100)], previous: forgiving.baselines(), now: 1_790_000_005,
                                reason: .normal, bootTime: 1_789_000_000, bootSession: "A")
    let committed = forgiving.transaction {
        forgiving.addBuckets(outcome.buckets, ssid: ssidPlaceholder, idle: false)
        forgiving.saveBaselines(outcome.baselines)
        forgiving.addEvents(outcome.events)
    }
    check(!committed, "a write failure swallowed inside a transaction still rolls it back")
    expect(forgiving.baselines()["en0"]?.bytesIn, 1_000, "so the baseline cannot move past bytes that were never written")

    // SQLite ends the transaction itself, as it does on a full disk. A write after that must not commit on its own.
    let ended = makeDatabase()
    ended.log = { _ in }
    ended.saveBaselines(["en0": RawCounter(bytesIn: 1_000, bytesOut: 100, at: 1_790_000_000, bootSession: "A", source: .mib64)])
    let endedCommitted = ended.transaction {
        try ended.exec("ROLLBACK;")                       // what SQLite does by itself on SQLITE_FULL
        ended.saveBaselines(["en0": RawCounter(bytesIn: 99_000, bytesOut: 100, at: 1_790_000_005, bootSession: "A", source: .mib64)])
    }
    check(!endedCommitted, "a transaction SQLite has already ended counts as failed")
    expect(ended.baselines()["en0"]?.bytesIn, 1_000, "and nothing written after the end commits on its own")

    // A real full disk, through SQLite's page limit, then room again. The filler rows sit in the
    // minutes the failing sample will write, an hour's gap spread minute by minute, so it needs new pages.
    let full = makeDatabase()
    full.log = { _ in }
    check(writeSample(full, raw: 1_000, at: 1_790_000_000, counterSource: nil)
          && writeSample(full, raw: 2_000, at: 1_790_000_005, counterSource: nil),
          "two samples before the disk fills")
    try! full.exec("PRAGMA wal_checkpoint(TRUNCATE);")
    var pages: Int64 = 0
    try! full.query("PRAGMA page_count;") { pages = $0.int(0) }
    try! full.exec("PRAGMA max_page_count=\(pages + 3);")
    let gapStart = Ledger.floorDiv(1_790_000_005, 60) + 1
    var filler: Int64 = 0
    while (try? full.run("INSERT INTO samples(minute,iface,ssid,bytes_in,bytes_out,idle,estimated) VALUES(?,?,?,1,1,0,0);",
                         [.int(gapStart + filler / 50), .text("en9:\(filler % 50)"), .text(ssidPlaceholder)])) != nil,
          filler < 100_000 { filler += 1 }
    check(filler < 100_000, "the page limit fills the file")
    check(!writeSample(full, raw: 51_000, at: 1_790_003_605, counterSource: nil), "a sample on a full disk fails")
    expect(full.baselines()["en0"]?.bytesIn, 2_000, "and its baseline stays put")
    try! full.exec("PRAGMA max_page_count=1073741823;")
    check(writeSample(full, raw: 52_000, at: 1_790_003_610, counterSource: nil), "with room again the next sample commits")
    expect(sumIn(full), 51_000, "samples since the first baseline still equal the raw counter minus it, through a full disk")
}

// MARK: - Recent events stop at the moment asked for

func checkRecentEventsStopAtTheMoment() {
    // Written out of order, so the order read back is the query's own.
    let db = makeDatabase()
    db.addEvents([600, 120, 360, 240, 480].map { LedgerEvent(ts: Int64($0), kind: "k\($0)", detail: "d\($0)") })
    expect(db.recentEvents(upTo: 600, limit: 10).map(\.ts), [600, 480, 360, 240, 120], "recent events come newest first")
    expect(db.recentEvents(upTo: 360, limit: 10).map(\.ts), [360, 240, 120],
           "and stop at the moment asked for, which is included")
    expect(db.recentEvents(upTo: 600, limit: 2).map(\.ts), [600, 480], "and stop at the limit")
    expect(db.recentEvents(upTo: 600, limit: 1).first, LedgerEvent(ts: 600, kind: "k600", detail: "d600"),
           "each event reads back whole")
    check(db.recentEvents(upTo: 119, limit: 10).isEmpty && makeDatabase().recentEvents(upTo: 600, limit: 10).isEmpty,
          "before the first event, or with none at all, there is nothing to list")
}

// MARK: - The demo opens its database strictly read only

func checkReadOnlyOpenChangesNothing() {
    let folder = scratchFolder + "demo_\(UUID().uuidString)"
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
    let oldPath = scratchFolder + "v1ro_\(UUID().uuidString).db"
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
