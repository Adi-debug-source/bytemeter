import Foundation
import SQLite3
import BytemeterCore

// Checks for the schema steps an existing database goes through when a new
// build opens it: the version 2 backfill of the estimated mark, the version 3
// estimated bytes, the version 4 drop of two indexes, and two processes
// migrating the same file at once.

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
    expect(rawInt(path, "PRAGMA user_version;"), 4, "the schema is now version 4")

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
    check(refusal.contains("is at schema version 2 and this build reads version 4. Run Bytemeter --dashboard on its folder once"),
          "a version 2 database is refused read only, with the reason and what to do, got: \(refusal)")
    expect(rawInt(path, "PRAGMA user_version;"), 2, "and is left at version 2")

    do {
        let db = try! Database(path: path)                             // runs the migration
        let aggregator = Aggregator(db: db, cal: london)
        expect(rawInt(path, "PRAGMA user_version;"), 4, "a version 2 database is brought to version 4")
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
               "a version 4 database opens read only, with the same figures")
    } catch {
        check(false, "a version 4 database opens read only: \(error)")
    }
}

// MARK: - The version 4 migration drops the two indexes on minute alone

/// Every row a query returns, each as its columns read as text and joined,
/// so rows with text in them can be compared whole.
private func rawLines(_ path: String, _ sql: String) -> [String] {
    var handle: OpaquePointer?
    var statement: OpaquePointer?
    guard sqlite3_open(path, &handle) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement); sqlite3_close(handle) }
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
    var lines: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        lines.append((0..<sqlite3_column_count(statement)).map { column in
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "NULL"
        }.joined(separator: "|"))
    }
    return lines
}

func checkVersion4DropsTheMinuteIndexes() {
    let minuteIndexes = "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN ('idx_samples_minute','idx_proc_minute');"
    let eventsIndex = "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_events_ts';"
    let everySample = "SELECT * FROM samples ORDER BY minute, iface, ssid;"
    let everyProc = "SELECT * FROM proc_samples ORDER BY minute, proc;"
    let schema = "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY name;"

    // Two hours of rows on two interfaces and three apps, as an old build wrote them.
    var rows = ""
    for step in Int64(0)..<120 {
        let minute = 29_600_000 + step
        rows += "INSERT INTO samples(minute,iface,ssid,bytes_in,bytes_out,idle) VALUES(\(minute),'en0','Home',\(1_000 + step * 7),\(100 + step),\(step % 2));\n"
        if step % 3 == 0 {
            rows += "INSERT INTO samples(minute,iface,ssid,bytes_in,bytes_out,idle) VALUES(\(minute),'en1','-',\(50_000 + step),\(3_000 + step),0);\n"
        }
        for proc in ["Safari", "Music", "cloudd"] where (step + Int64(proc.count)) % 2 == 0 {
            rows += "INSERT INTO proc_samples(minute,proc,bytes_in,bytes_out) VALUES(\(minute),'\(proc)',\(400 + step * 3),\(40 + step));\n"
        }
    }
    let v1 = scratchFolder + "v1idx_\(UUID().uuidString).db"
    check(rawExec(v1, schemaVersion1 + rows), "the schema 1 fixture for the index drop builds")
    let v3 = scratchFolder + "v3idx_\(UUID().uuidString).db"
    check(rawExec(v3, schemaVersion1 + """
        ALTER TABLE samples ADD COLUMN estimated INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE samples ADD COLUMN est_in INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE samples ADD COLUMN est_out INTEGER NOT NULL DEFAULT 0;
        PRAGMA user_version=3;

        """ + rows + "UPDATE samples SET estimated=1, est_in=bytes_in, est_out=bytes_out WHERE minute%10=0;\n"),
          "the schema 3 fixture for the index drop builds")

    for (path, from) in [(v1, 1), (v3, 3)] {
        expect(rawInt(path, minuteIndexes), 2, "a version \(from) database has both indexes on minute alone")
        let samplesBefore = rawLines(path, "SELECT minute, iface, ssid, bytes_in, bytes_out, idle FROM samples ORDER BY minute, iface, ssid;")
        let procsBefore = rawLines(path, everyProc)
        let estimatedBefore = from == 3 ? rawLines(path, "SELECT minute, iface, ssid, estimated, est_in, est_out FROM samples ORDER BY minute, iface, ssid;") : []
        check(samplesBefore.count > 120 && procsBefore.count > 120, "the version \(from) fixture has rows in both tables")

        _ = try! Database(path: path)                                  // runs the migration
        expect(rawInt(path, "PRAGMA user_version;"), 4, "a version \(from) database is brought to version 4")
        expect(rawInt(path, minuteIndexes), 0, "and has neither index on minute alone")
        expect(rawInt(path, eventsIndex), 1, "and keeps the index on event times")
        expect(rawLines(path, "SELECT minute, iface, ssid, bytes_in, bytes_out, idle FROM samples ORDER BY minute, iface, ssid;"),
               samplesBefore, "every minute row of the version \(from) database is intact")
        expect(rawLines(path, everyProc), procsBefore, "every per-app row of the version \(from) database is intact")
        if from == 3 {
            expect(rawLines(path, "SELECT minute, iface, ssid, estimated, est_in, est_out FROM samples ORDER BY minute, iface, ssid;"),
                   estimatedBefore, "and every estimated share of the version 3 database is intact")
            expect(rawInt(path, "SELECT COUNT(*) FROM events;"), 0, "the step writes no event, because nothing the user sees changes")
        }

        // Opening it again changes nothing: the version, the schema, every row.
        let schemaAfter = rawLines(path, schema)
        let samplesAfter = rawLines(path, everySample)
        let eventsAfter = rawLines(path, "SELECT * FROM events ORDER BY rowid;")
        _ = try! Database(path: path)
        expect(rawInt(path, "PRAGMA user_version;"), 4, "opening the migrated version \(from) database again leaves it at version 4")
        expect(rawLines(path, schema), schemaAfter, "and leaves its schema exactly as it was")
        expect(rawLines(path, everySample), samplesAfter, "and every minute row")
        expect(rawLines(path, everyProc), procsBefore, "and every per-app row")
        expect(rawLines(path, "SELECT * FROM events ORDER BY rowid;"), eventsAfter, "and writes no event")
    }

    // A new database is made at version 4 and never has them.
    let fresh = makeDatabase()
    fresh.addBuckets([BucketDelta(minute: 29_600_000, iface: "en0", bytesIn: 4_000, bytesOut: 400)],
                     ssid: ssidPlaceholder, idle: false)
    fresh.addProcBuckets(minute: 29_600_000, deltas: ["Safari": (bytesIn: 3_000, bytesOut: 300)])
    expect(rawInt(fresh.path, "PRAGMA user_version;"), 4, "a new database is made at version 4")
    expect(rawInt(fresh.path, minuteIndexes), 0, "and has neither index on minute alone")
    expect(rawInt(fresh.path, eventsIndex), 1, "and has the index on event times")

    // Every range the engine reads, sums, marks or prunes on these tables is
    // searched on the primary key's index, never scanned. The plans come
    // from the engine's own SQLite, through `Database.query`. The SQL is
    // as Aggregation.swift and Maintenance.swift write it, with the hour
    // start the prune groups by in the shape `hourStartSQL` gives it.
    let hour = "(CASE WHEN minute<29600120 THEN MAX(29600000, minute-(((minute+60)%60)+60)%60) ELSE minute END)"
    let rangeQueries: [(table: String, sql: String)] = [
        ("samples", """
            SELECT COALESCE(SUM(bytes_in),0), COALESCE(SUM(bytes_out),0),
                   COALESCE(SUM(est_in),0), COALESCE(SUM(est_out),0)
            FROM samples WHERE minute>=? AND minute<?;
            """),
        ("samples", """
            SELECT minute, SUM(bytes_in), SUM(bytes_out), MIN(idle), SUM(est_in), SUM(est_out)
            FROM samples WHERE minute>=? AND minute<? GROUP BY minute ORDER BY minute;
            """),
        ("samples", "SELECT MIN(minute) FROM samples WHERE minute>=? AND minute<?;"),
        ("proc_samples", """
            SELECT proc, SUM(bytes_in), SUM(bytes_out) FROM proc_samples
            WHERE minute>=? AND minute<? GROUP BY proc
            ORDER BY SUM(bytes_in)+SUM(bytes_out) DESC LIMIT ?;
            """),
        ("samples", "SELECT idle, SUM(bytes_in), SUM(bytes_out) FROM samples WHERE minute>=? AND minute<? GROUP BY idle;"),
        ("samples", """
            SELECT iface, SUM(bytes_in), SUM(bytes_out) FROM samples
            WHERE minute>=? AND minute<? GROUP BY iface ORDER BY SUM(bytes_in)+SUM(bytes_out) DESC;
            """),
        ("samples", """
            SELECT ssid, SUM(bytes_in), SUM(bytes_out) FROM samples
            WHERE minute>=? AND minute<? GROUP BY ssid ORDER BY SUM(bytes_in)+SUM(bytes_out) DESC;
            """),
        ("samples", "SELECT MIN(minute) FROM samples WHERE minute<?;"),
        ("proc_samples", "SELECT MIN(minute) FROM proc_samples WHERE minute<?;"),
        ("samples", "SELECT COUNT(*), MIN(\(hour)) FROM samples WHERE minute<? AND minute!=\(hour);"),
        ("proc_samples", "SELECT COUNT(*), MIN(\(hour)) FROM proc_samples WHERE minute<? AND minute!=\(hour);"),
        ("samples", """
            SELECT \(hour) AS m, iface, ssid,
                   SUM(bytes_in) AS bi, SUM(bytes_out) AS bo, MIN(idle) AS idl,
                   MAX(estimated) AS est, SUM(est_in) AS ei, SUM(est_out) AS eo
            FROM samples WHERE minute>=? AND minute<? GROUP BY m, iface, ssid;
            """),
        ("samples", "DELETE FROM samples WHERE minute>=? AND minute<?;"),
        ("proc_samples", """
            SELECT \(hour) AS m, proc,
                   SUM(bytes_in) AS bi, SUM(bytes_out) AS bo
            FROM proc_samples WHERE minute>=? AND minute<? GROUP BY m, proc;
            """),
        ("proc_samples", "DELETE FROM proc_samples WHERE minute>=? AND minute<?;"),
        ("samples", "UPDATE samples SET estimated=1 WHERE iface=? AND minute>=? AND minute<=? AND estimated=0;"),
    ]
    for (name, db) in [("a new database", fresh), ("a migrated version 1 database", try! Database(path: v1))] {
        for query in rangeQueries {
            var plan: [String] = []
            try? db.query("EXPLAIN QUERY PLAN " + query.sql) { plan.append($0.string(3)) }
            let key = "INDEX sqlite_autoindex_\(query.table)_1 (minute"
            check(plan.contains { $0.hasPrefix("SEARCH") && $0.contains(key) } && !plan.contains { $0.hasPrefix("SCAN") },
                  "in \(name), the engine's range query is searched on the primary key, got \(plan) for: \(query.sql)")
        }
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
    expect(rawInt(path, "PRAGMA user_version;"), 4, "the file ends at version 4")
    expect(rawInt(path, "SELECT COUNT(*) FROM events WHERE kind='estimated_backfill';"), 1, "and the migration ran exactly once")
}
