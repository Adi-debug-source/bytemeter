import Foundation
import SQLite3
import BytemeterCore

// What every check file shares: the counters and the two ways to record a
// check, the scratch folder every database goes in, and the helpers more than
// one subject uses to build a database or read one back. main.swift runs the
// checks in order and prints the result.

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

// Every database the checks make goes in one folder for this run, removed at
// the end, so running the self-test leaves nothing behind in the temp folder.
// A global outside main.swift is set up the first time it is read, so the
// closure below makes the folder then.
let scratchFolder: String = {
    let folder = NSTemporaryDirectory() + "bytemeter_selftest_\(UUID().uuidString)/"
    try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    return folder
}()

func makeDatabase() -> Database {
    let path = scratchFolder + "\(UUID().uuidString).db"
    return try! Database(path: path)
}

func reading(_ name: String, _ bytesIn: UInt64, _ bytesOut: UInt64) -> InterfaceReading {
    InterfaceReading(name: name, bytesIn: bytesIn, bytesOut: bytesOut)
}

/// A reading from the 32 bit getifaddrs fallback.
func reading32(_ name: String, _ bytesIn: UInt64, _ bytesOut: UInt64) -> InterfaceReading {
    InterfaceReading(name: name, bytesIn: bytesIn, bytesOut: bytesOut, source: .ifdata32)
}

let london = BytemeterCalendar(timeZone: TimeZone(identifier: "Europe/London")!)

// MARK: - Raw SQL, and rows read back

/// Run raw SQL against a file, as the first release would have, without going
/// through `Database` and its migration.
func rawExec(_ path: String, _ sql: String) -> Bool {
    var handle: OpaquePointer?
    guard sqlite3_open(path, &handle) == SQLITE_OK else { return false }
    defer { sqlite3_close(handle) }
    return sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
}

/// The first column of the first row a query returns, or -1 if there is none.
func rawInt(_ path: String, _ sql: String) -> Int64 {
    var handle: OpaquePointer?
    var statement: OpaquePointer?
    guard sqlite3_open(path, &handle) == SQLITE_OK else { return -1 }
    defer { sqlite3_finalize(statement); sqlite3_close(handle) }
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW else { return -1 }
    return sqlite3_column_int64(statement, 0)
}

/// Every row a query returns, each as its integer columns.
func rawRows(_ path: String, _ sql: String) -> [[Int64]] {
    var handle: OpaquePointer?
    var statement: OpaquePointer?
    guard sqlite3_open(path, &handle) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement); sqlite3_close(handle) }
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
    var rows: [[Int64]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        rows.append((0..<sqlite3_column_count(statement)).map { sqlite3_column_int64(statement, $0) })
    }
    return rows
}

/// A row's estimated mark, or -1 if there is no row.
func estimatedFlag(_ db: Database, minute: Int64, iface: String = "en0") -> Int64 {
    var flag: Int64 = -1
    try? db.query("SELECT estimated FROM samples WHERE minute=? AND iface=?;",
                  [.int(minute), .text(iface)]) { flag = $0.int(0) }
    return flag
}

/// A row's estimated bytes, down then up, or nothing if there is no row.
func estimatedBytes(_ db: Database, minute: Int64, iface: String = "en0") -> [Int64] {
    var bytes: [Int64] = []
    try? db.query("SELECT est_in, est_out FROM samples WHERE minute=? AND iface=?;",
                  [.int(minute), .text(iface)]) { bytes = [$0.int(0), $0.int(1)] }
    return bytes
}

/// The bytes down on one interface's rows, or -1 if the query fails.
func sumIn(_ db: Database, iface: String = "en0") -> Int64 {
    var total: Int64 = -1
    try? db.query("SELECT COALESCE(SUM(bytes_in),0) FROM samples WHERE iface=?;", [.text(iface)]) { total = $0.int(0) }
    return total
}

/// Bytes per local hour, keyed by the hour as the wall clock showed it.
func localHourTotals(_ db: Database, _ cal: BytemeterCalendar) -> [String: UInt64] {
    var out: [String: UInt64] = [:]
    try! db.query("SELECT minute, SUM(bytes_in) FROM samples GROUP BY minute;") { row in
        let c = cal.calendar.dateComponents([.year, .month, .day, .hour], from: BytemeterCalendar.date(fromMinute: row.int(0)))
        out["\(c.year!)-\(c.month!)-\(c.day!) \(c.hour!)", default: 0] += row.uint(1)
    }
    return out
}

// MARK: - Writing as the sampler does

/// One sample exactly as the sampler writes it: one reading, written whole in one transaction.
/// A check that counts pages passes nil for the counter source, so the pages hold only the rows it accounts for.
func writeSample(_ db: Database, raw: UInt64, at: Int64, counterSource: CounterSource? = .mib64) -> Bool {
    let outcome = Ledger.ingest(readings: [reading("en0", raw, raw / 10)], previous: db.baselines(), now: at,
                                reason: .normal, bootTime: 1_789_000_000, bootSession: "A")
    return db.transaction {
        try db.writeReading(outcome, ssid: ssidPlaceholder, idle: false, reason: .normal, counterSource: counterSource)
    }
}

// MARK: - The schema the first release created

/// A schema 1 database, exactly as the first release created it. A check that
/// needs an older file starts from this and adds its own rows or steps.
let schemaVersion1 = """
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
