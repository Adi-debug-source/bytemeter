import Foundation
import SQLite3
import BytemeterCore

// Checks for the schema steps an existing database goes through when a new
// build opens it: the version 2 backfill of the estimated mark, the version 3
// estimated bytes, and two processes migrating the same file at once.

// MARK: - The version 2 migration finds the old spread rows, and only them

func checkVersion2MarksOnlySpreadRows() {
    // A schema 1 database, exactly as the first release created it.
    let path = scratchFolder + "v1_\(UUID().uuidString).db"
    var sql = schemaVersion1

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
                                    reason: reason, bootTime: nil)
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
    expect(rawInt(path, "PRAGMA user_version;"), 3, "the schema is now version 3")

    // The same open goes on through version 3's step, which reads the marks
    // version 2's step has just made: a marked row keeps all its bytes as
    // estimated, the wake minutes included, and no other row has any.
    expect(rawInt(path, "SELECT COUNT(*) FROM samples WHERE estimated!=0 AND (est_in!=bytes_in OR est_out!=bytes_out);"), 0,
           "a version 1 file goes through both steps: every row marked by the backfill keeps its bytes as estimated")
    expect(rawInt(path, "SELECT COUNT(*) FROM samples WHERE estimated=0 AND (est_in!=0 OR est_out!=0);"), 0,
           "and no unmarked row has any estimated bytes")
    check(rawInt(path, "SELECT SUM(est_in) FROM samples;") > 0, "the backfilled rows carry estimated bytes")

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

// MARK: - The version 3 migration keeps every figure exactly as it was

func checkVersion3KeepsEveryFigure() {
    // A schema 2 database, as 1.0.0 created it: version 1's tables, then the estimated column.
    let path = scratchFolder + "v2_\(UUID().uuidString).db"
    var sql = schemaVersion1 + """
    ALTER TABLE samples ADD COLUMN estimated INTEGER NOT NULL DEFAULT 0;
    PRAGMA user_version=2;

    """
    // Six hours on two interfaces and two networks, written with 1.0.0's
    // upsert: an hour asleep spread on en0, ending in a wake minute that
    // also holds bytes measured after waking, and a short spread on en1.
    let start: Int64 = 29_500_000
    func write(_ step: Int64, _ iface: String, _ ssid: String, _ bytesIn: Int64, _ bytesOut: Int64, estimated: Bool) {
        sql += """
        INSERT INTO samples(minute,iface,ssid,bytes_in,bytes_out,idle,estimated)
        VALUES(\(start + step),'\(iface)','\(ssid)',\(bytesIn),\(bytesOut),0,\(estimated ? 1 : 0))
        ON CONFLICT(minute,iface,ssid) DO UPDATE SET bytes_in=bytes_in+excluded.bytes_in,
            bytes_out=bytes_out+excluded.bytes_out, idle=MIN(idle,excluded.idle), estimated=MAX(estimated,excluded.estimated);

        """
    }
    for step in Int64(0)..<360 {
        if (61...120).contains(step) { write(step, "en0", ssidPlaceholder, 200_003, 20_001, estimated: true) }
        if !(61..<120).contains(step) {
            write(step, "en0", ssidPlaceholder, 1_000 + step * 37 % 500, 100 + step % 13, estimated: false)
        }
        if (180..<240).contains(step) { write(step, "en1", "Cafe", 50_000 + step, 3_000, estimated: (200...202).contains(step)) }
    }
    check(rawExec(path, sql), "the schema 2 fixture builds")

    // The figures as 1.0.0 worked them out, from the mark.
    let minutesBefore = rawRows(path, """
        SELECT minute, SUM(bytes_in), SUM(bytes_out),
               SUM(CASE WHEN estimated!=0 THEN bytes_in ELSE 0 END), SUM(CASE WHEN estimated!=0 THEN bytes_out ELSE 0 END)
        FROM samples GROUP BY minute ORDER BY minute;
        """)
    func markedTotals(_ range: MinuteRange) -> Totals {
        let row = rawRows(path, """
            SELECT COALESCE(SUM(bytes_in),0), COALESCE(SUM(bytes_out),0),
                   COALESCE(SUM(CASE WHEN estimated!=0 THEN bytes_in ELSE 0 END),0),
                   COALESCE(SUM(CASE WHEN estimated!=0 THEN bytes_out ELSE 0 END),0)
            FROM samples WHERE minute>=\(range.start) AND minute<\(range.end);
            """).first ?? [-1, -1, -1, -1]
        return Totals(bytesIn: UInt64(row[0]), bytesOut: UInt64(row[1]), estimatedIn: UInt64(row[2]), estimatedOut: UInt64(row[3]))
    }
    let whole = MinuteRange(start: start, end: start + 360)
    let wakeMinute = MinuteRange(start: start + 120, end: start + 121)
    let ranges = (Int64(0)..<6).map { MinuteRange(start: start + $0 * 60, end: start + $0 * 60 + 60) }
        + [whole, MinuteRange(start: start + 61, end: start + 121), wakeMinute, MinuteRange(start: start + 200, end: start + 202)]
    let totalsBefore = ranges.map(markedTotals)
    let wholeBefore = markedTotals(whole)
    let rowsBefore = rawInt(path, "SELECT COUNT(*) FROM samples;")
    expect(minutesBefore.count, 360, "the fixture has a row for every minute")
    check(wholeBefore.estimatedIn > 0 && wholeBefore.estimatedOut > 0, "the fixture has estimated rows")
    expect(markedTotals(wakeMinute).estimatedIn, markedTotals(wakeMinute).bytesIn,
           "1.0.0 counts the wake minute as estimated in full, measured bytes included")

    // The read only open, which --demo uses, refuses it rather than reading it wrongly or upgrading it.
    var refusal = ""
    do { _ = try Database(readOnlyPath: path) } catch { refusal = "\(error)" }
    check(refusal.contains("is at schema version 2 and this build reads version 3. Run Bytemeter --dashboard on its folder once"),
          "a version 2 database is refused read only, with the reason and what to do, got: \(refusal)")
    expect(rawInt(path, "PRAGMA user_version;"), 2, "and is left at version 2")

    do {
        let db = try! Database(path: path)                             // runs the migration
        let aggregator = Aggregator(db: db, cal: london)
        expect(rawInt(path, "PRAGMA user_version;"), 3, "a version 2 database is brought to version 3")
        expect(rawInt(path, "SELECT COUNT(*) FROM samples WHERE estimated!=0 AND (est_in!=bytes_in OR est_out!=bytes_out);"), 0,
               "every marked row keeps exactly its bytes as estimated")
        expect(rawInt(path, "SELECT COUNT(*) FROM samples WHERE estimated=0 AND (est_in!=0 OR est_out!=0);"), 0,
               "and every unmarked row none")
        expect(rawInt(path, "SELECT COUNT(*) FROM samples;"), rowsBefore, "the step leaves the row count alone")
        expect(rawInt(path, "SELECT COUNT(*) FROM events;"), 0, "and writes no event, because nothing the user sees changes")
        expect(aggregator.minuteRows(MinuteRange(start: 0, end: .max)).map {
                   [$0.minute, Int64($0.bytesIn), Int64($0.bytesOut), Int64($0.estimatedIn), Int64($0.estimatedOut)]
               }, minutesBefore, "every minute reads as it did before the step, estimated share included")
        // A closure rather than `aggregator.totals` itself, which kept the
        // database open after this block, and the read only open below needs
        // it closed, with its write-ahead log folded into the file.
        expect(ranges.map { aggregator.totals($0) }, totalsBefore,
               "every total reads as it did before the step, estimated share included")
    }

    let everyRow = "SELECT minute, bytes_in, bytes_out, idle, estimated, est_in, est_out FROM samples ORDER BY minute, iface, ssid;"
    let rowsAfter = rawRows(path, everyRow)
    _ = try! Database(path: path)
    expect(rawRows(path, everyRow), rowsAfter, "opening it again changes nothing")

    do {
        let reader = try Database(readOnlyPath: path)
        expect(Aggregator(db: reader, cal: london).totals(whole), wholeBefore,
               "a version 3 database opens read only, with the same figures")
    } catch {
        check(false, "a version 3 database opens read only: \(error)")
    }
}

// MARK: - Two processes migrating the same file

private final class OpenResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: String] = [:]
    func set(_ index: Int, _ value: String) { lock.lock(); values[index] = value; lock.unlock() }
    var sorted: [String] { lock.lock(); defer { lock.unlock() }; return values.keys.sorted().map { values[$0]! } }
}

func checkTwoProcessesCanMigrateAtOnce() {
    let path = scratchFolder + "race_\(UUID().uuidString).db"
    // The first release's schema in write-ahead mode, with one row to migrate.
    check(rawExec(path, "PRAGMA journal_mode=WAL;\n" + schemaVersion1 + "INSERT INTO samples VALUES(100,'en0','-',5,5,0);\n"),
          "the schema 1 fixture for the race builds")
    // A third connection holds the write lock, so both openers read version 1 before either can migrate.
    var holder: OpaquePointer?
    check(sqlite3_open(path, &holder) == SQLITE_OK && sqlite3_exec(holder, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK,
          "the lock is held")
    let results = OpenResults()
    let group = DispatchGroup()
    for index in 0..<2 {
        group.enter()
        Thread.detachNewThread {
            do { _ = try Database(path: path); results.set(index, "opened") } catch { results.set(index, "\(error)") }
            group.leave()
        }
    }
    Thread.sleep(forTimeInterval: 0.5)
    sqlite3_exec(holder, "COMMIT;", nil, nil, nil)
    sqlite3_close(holder)
    group.wait()
    expect(results.sorted, ["opened", "opened"], "two processes opening an old database at once both succeed")
    expect(rawInt(path, "PRAGMA user_version;"), 3, "the file ends at version 3")
    expect(rawInt(path, "SELECT COUNT(*) FROM events WHERE kind='estimated_backfill';"), 1, "and the migration ran exactly once")
}
