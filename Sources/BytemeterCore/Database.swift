import Foundation
import SQLite3

public enum BytemeterError: Error, CustomStringConvertible {
    case open(String)
    case sql(String, String)

    public var description: String {
        switch self {
        case .open(let m): return "could not open the database: \(m)"
        case .sql(let s, let m): return "SQL failed: \(m) [\(s)]"
        }
    }
}

/// SQLite is told to keep the text we hand it, rather than assuming the buffer
/// outlives the call. Without this, bound strings can be freed before use.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum Binding {
    case int(Int64)
    case text(String)
}

/// A single prepared statement, wrapped so the call sites read as SQL rather
/// than as C pointer juggling.
public final class Statement {
    fileprivate var handle: OpaquePointer?
    private let sql: String

    fileprivate init(db: OpaquePointer?, sql: String) throws {
        self.sql = sql
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK else {
            throw BytemeterError.sql(sql, String(cString: sqlite3_errmsg(db)))
        }
    }

    deinit { sqlite3_finalize(handle) }

    fileprivate func bind(_ values: [Binding]) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(handle, index, v)
            case .text(let v): sqlite3_bind_text(handle, index, v, -1, sqliteTransient)
            }
        }
    }

    public func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }

    /// False for SQL NULL, which `int` would read as 0.
    public func isNotNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) != SQLITE_NULL }

    public func uint(_ column: Int32) -> UInt64 {
        let v = sqlite3_column_int64(handle, column)
        return v < 0 ? 0 : UInt64(v)
    }

    public func string(_ column: Int32) -> String {
        guard let c = sqlite3_column_text(handle, column) else { return "" }
        return String(cString: c)
    }
}

/// Not thread safe by itself. One serial queue owns it; see Sampler.
public final class Database {
    private var handle: OpaquePointer?
    public let path: String

    /// Where a failed transaction is reported. Standard error by default;
    /// replaceable so the self-test can count the lines.
    public var log: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    /// True between BEGIN and COMMIT or ROLLBACK of `inTransaction`.
    private var transactionOpen = false
    /// The first write that failed inside the open transaction, kept even if
    /// the caller swallowed it, so the transaction can never commit without it.
    private var transactionFault: Error?
    /// Transactions rolled back in a row. The first one is logged, the rest
    /// only counted, so a full disk says so once rather than every 5 seconds.
    public private(set) var failedTransactionsInARow = 0

    public init(path: String) throws {
        self.path = path
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, db != nil else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw BytemeterError.open(message)
        }
        handle = db
        sqlite3_busy_timeout(handle, 3_000)
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try migrate()
    }

    /// The schema version this build writes and reads. Raise it with each new
    /// step in `migrate()`.
    public static let schemaVersion: Int64 = 2

    /// Open an existing database for reading only, for `--demo`, which must
    /// leave its folder exactly as it found it.
    ///
    /// Opened immutable: no migration, no journal mode, no locks, and nothing
    /// written, not even the -wal and -shm files that WAL mode normally keeps
    /// beside the database. Immutable means SQLite reads the main file alone,
    /// so a write-ahead log that still holds changes is refused rather than
    /// silently ignored, and so is a file at a different schema version.
    public init(readOnlyPath path: String) throws {
        self.path = path
        guard FileManager.default.fileExists(atPath: path) else {
            throw BytemeterError.open("there is no database at \(path)")
        }
        let wal = (try? FileManager.default.attributesOfItem(atPath: path + "-wal"))?[.size] as? NSNumber
        if let size = wal, size.int64Value > 0 {
            throw BytemeterError.open("\(path) has changes in its write-ahead log that are not in the file yet. "
                                      + "Quit whatever has it open, then try again")
        }
        let uri = URL(fileURLWithPath: path).absoluteString + "?immutable=1"
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, db != nil else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw BytemeterError.open(message)
        }
        handle = db
        var version: Int64 = -1
        try query("PRAGMA user_version;") { version = $0.int(0) }
        guard version == Self.schemaVersion else {
            throw BytemeterError.open("\(path) is at schema version \(version) and this build reads version "
                                      + "\(Self.schemaVersion). Run Bytemeter --dashboard on its folder once to "
                                      + "bring it up to date")
        }
    }

    deinit { sqlite3_close(handle) }

    // MARK: - Plumbing

    public func exec(_ sql: String) throws {
        try guardOpenTransaction(sql)
        do { try rawExec(sql) } catch { noteFault(error); throw error }
    }

    public func run(_ sql: String, _ binds: [Binding] = []) throws {
        try guardOpenTransaction(sql)
        do {
            let statement = try Statement(db: handle, sql: sql)
            statement.bind(binds)
            let result = sqlite3_step(statement.handle)
            guard result == SQLITE_DONE || result == SQLITE_ROW else {
                throw BytemeterError.sql(sql, String(cString: sqlite3_errmsg(handle)))
            }
        } catch {
            noteFault(error)
            throw error
        }
    }

    private func rawExec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw BytemeterError.sql(sql, message)
        }
    }

    /// Inside a transaction, refuse to run anything once it has gone wrong.
    /// Two ways it can: a write already failed, or SQLite ended the
    /// transaction itself, which it does on a full disk or an I/O error.
    /// In the second case a statement run now would not join the
    /// transaction but commit on its own, which is how a baseline used to
    /// move forward while the bytes it measured were lost.
    private func guardOpenTransaction(_ sql: String) throws {
        guard transactionOpen else { return }
        if let fault = transactionFault { throw fault }
        if sqlite3_get_autocommit(handle) != 0 {
            let error = BytemeterError.sql(sql, "the transaction was already ended by SQLite, so this was not run")
            transactionFault = error
            throw error
        }
    }

    private func noteFault(_ error: Error) {
        if transactionOpen && transactionFault == nil { transactionFault = error }
    }

    public func query(_ sql: String, _ binds: [Binding] = [], each: (Statement) -> Void) throws {
        let statement = try Statement(db: handle, sql: sql)
        statement.bind(binds)
        while sqlite3_step(statement.handle) == SQLITE_ROW { each(statement) }
    }

    /// Run `body` as one transaction: all of it commits, or none of it does.
    /// Any failure rolls the lot back and is thrown, including a write whose
    /// error `body` caught and ignored, and SQLite ending the transaction on
    /// its own. Not reentrant.
    public func inTransaction(_ body: () throws -> Void) throws {
        guard !transactionOpen else {
            throw BytemeterError.sql("BEGIN IMMEDIATE;", "a transaction is already open on this connection")
        }
        try rawExec("BEGIN IMMEDIATE;")
        transactionOpen = true
        transactionFault = nil
        defer {
            transactionOpen = false
            transactionFault = nil
        }
        do {
            try body()
            if let fault = transactionFault { throw fault }
            guard sqlite3_get_autocommit(handle) == 0 else {
                throw BytemeterError.sql("COMMIT;", "the transaction was already ended by SQLite")
            }
            try rawExec("COMMIT;")
        } catch {
            if sqlite3_get_autocommit(handle) == 0 { try? rawExec("ROLLBACK;") }
            throw error
        }
    }

    /// The same, for callers with nothing to do about a failure but carry
    /// on: true if it committed. A failure is logged the first time only,
    /// and the end of a run of failures is logged once too.
    @discardableResult
    public func transaction(_ body: () throws -> Void) -> Bool {
        do {
            try inTransaction(body)
            if failedTransactionsInARow > 0 {
                log("Bytemeter: writing again after \(failedTransactionsInARow) failed attempts.")
                failedTransactionsInARow = 0
            }
            return true
        } catch {
            if failedTransactionsInARow == 0 {
                let oneLine = "\(error)".split(whereSeparator: \.isWhitespace).joined(separator: " ")
                log("Bytemeter: a write failed and was rolled back, so nothing was half written: \(oneLine). "
                    + "Further failures are counted but not logged until a write succeeds.")
            }
            failedTransactionsInARow += 1
            return false
        }
    }

    // MARK: - Schema

    private func userVersion() throws -> Int64 {
        var version: Int64 = 0
        try query("PRAGMA user_version;") { version = $0.int(0) }
        return version
    }

    /// Bring the file up to `schemaVersion`, as one transaction.
    ///
    /// Two processes can open the same file at once, the app and a
    /// `--dashboard` run for example. Both read the version, both find it
    /// old, and one waits for the other's write lock. So the version is read
    /// again once the lock is held, and if the other process has already
    /// done the work there is nothing left to do. Every step, the version
    /// number with it, commits together or not at all, so a failure leaves
    /// the file as it was and the next launch tries again.
    private func migrate() throws {
        guard try userVersion() < Self.schemaVersion else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            let version = try userVersion()
            if version < Self.schemaVersion {
                try migrateSteps(from: version)
                try exec("PRAGMA user_version=\(Self.schemaVersion);")
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func migrateSteps(from version: Int64) throws {
        if version < 1 {
            try exec("""
            CREATE TABLE IF NOT EXISTS samples(
                minute    INTEGER NOT NULL,
                iface     TEXT    NOT NULL,
                ssid      TEXT    NOT NULL,
                bytes_in  INTEGER NOT NULL DEFAULT 0,
                bytes_out INTEGER NOT NULL DEFAULT 0,
                idle      INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(minute, iface, ssid)
            );
            CREATE TABLE IF NOT EXISTS proc_samples(
                minute    INTEGER NOT NULL,
                proc      TEXT    NOT NULL,
                bytes_in  INTEGER NOT NULL DEFAULT 0,
                bytes_out INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(minute, proc)
            );
            CREATE TABLE IF NOT EXISTS state(
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS events(
                ts     INTEGER NOT NULL,
                kind   TEXT    NOT NULL,
                detail TEXT    NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS idx_samples_minute ON samples(minute);
            CREATE INDEX IF NOT EXISTS idx_proc_minute    ON proc_samples(minute);
            CREATE INDEX IF NOT EXISTS idx_events_ts      ON events(ts);
            """)
        }

        if version < 2 {
            // Version 2 marks rows whose minute is an estimate.
            try exec("ALTER TABLE samples ADD COLUMN estimated INTEGER NOT NULL DEFAULT 0;")
            // A brand new database has nothing to mark and nothing to report.
            if version >= 1 {
                let result = try markPastSpreads()
                let detail = "Marked \(result.rows) minute rows as estimated, from \(result.gaps) earlier gaps "
                    + "whose traffic was spread evenly rather than measured minute by minute. "
                    + "\(result.skipped) gap events could not be read and were left unmarked. "
                    + "No byte moved: totals are unchanged, only the timing of those rows is uncertain."
                // Not addEvent, which forgives a failure: the record of the
                // backfill commits with the backfill or not at all.
                try run("INSERT INTO events(ts,kind,detail) VALUES(?,?,?);",
                        [.int(Int64(Date().timeIntervalSince1970)), .text("estimated_backfill"), .text(detail)])
            }
        }
    }

    /// Before version 2 nothing recorded which rows were spread. Each spread
    /// wrote a `gap_` event at the wake moment saying how many minutes it
    /// covered, and those are exactly the minutes ending at the event, so the
    /// rows can be found without guessing. `gap_too_long` is left out: it put
    /// its bytes in a single minute and never fired before this version.
    ///
    /// The wake minute is marked too, although it also holds bytes measured
    /// after waking. Conservative on purpose: a mixed minute is drawn as
    /// estimated rather than an estimate drawn as measured.
    private func markPastSpreads() throws -> (gaps: Int, rows: Int64, skipped: Int) {
        var spreads: [(ts: Int64, detail: String)] = []
        try query("""
            SELECT ts, detail FROM events
            WHERE kind LIKE 'gap\\_%' ESCAPE '\\' AND kind != 'gap_too_long' ORDER BY ts;
            """) { spreads.append(($0.int(0), $0.string(1))) }

        var gaps = 0
        var rows: Int64 = 0
        var skipped = 0
        for spread in spreads {
            guard let window = Ledger.spreadWindow(eventTs: spread.ts, detail: spread.detail) else {
                skipped += 1
                continue
            }
            try run("""
                UPDATE samples SET estimated=1
                WHERE iface=? AND minute>=? AND minute<=? AND estimated=0;
                """, [.text(window.iface), .int(window.firstMinute), .int(window.lastMinute)])
            rows += Int64(sqlite3_changes(handle))
            gaps += 1
        }
        return (gaps, rows, skipped)
    }

    // MARK: - State

    public func state(_ key: String) -> String? {
        var value: String?
        try? query("SELECT value FROM state WHERE key=?;", [.text(key)]) { value = $0.string(0) }
        return value
    }

    /// Forgiving: a failure is dropped. Inside a transaction it still rolls
    /// the transaction back; see `inTransaction`.
    public func setState(_ key: String, _ value: String) {
        try? writeState(key, value)
    }

    public func writeState(_ key: String, _ value: String) throws {
        try run("INSERT INTO state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
                [.text(key), .text(value)])
    }

    public func flag(_ key: String, default fallback: Bool) -> Bool {
        guard let raw = state(key) else { return fallback }
        return raw == "1" || raw == "true"
    }

    public func setFlag(_ key: String, _ value: Bool) { setState(key, value ? "1" : "0") }

    public func number(_ key: String, default fallback: Int64) -> Int64 {
        guard let raw = state(key), let value = Int64(raw) else { return fallback }
        return value
    }

    // MARK: - Raw counters

    /// Every saved baseline. One saved before sources were kept is given one
    /// where the database can say: earlier versions stored the source of the
    /// whole last snapshot under `counter_source`. If that was the 64 bit
    /// counter, so was every baseline. If it was the 32 bit one, a value
    /// that fits in 32 bits is taken as 32 bit, and the ledger works out the
    /// rest (see `Ledger.assumedSource`).
    public func baselines() -> [String: RawCounter] {
        var out: [String: RawCounter] = [:]
        try? query("SELECT key, value FROM state WHERE key LIKE 'raw:%';") { row in
            let iface = String(row.string(0).dropFirst(4))
            if let counter = RawCounter(encoded: row.string(1)) { out[iface] = counter }
        }
        if out.values.contains(where: { $0.source == nil }),
           let legacy = state(StateKey.counterSource).flatMap(CounterSource.init(rawValue:)) {
            for (iface, counter) in out where counter.source == nil {
                var known = counter
                let fits32 = counter.bytesIn <= UInt64(UInt32.max) && counter.bytesOut <= UInt64(UInt32.max)
                known.source = legacy == .ifdata32 && fits32 ? .ifdata32 : .mib64
                out[iface] = known
            }
        }
        return out
    }

    /// Forgiving: a failure is dropped. Inside a transaction it still rolls
    /// the transaction back; see `inTransaction`.
    public func saveBaselines(_ baselines: [String: RawCounter]) {
        try? writeBaselines(baselines)
    }

    public func writeBaselines(_ baselines: [String: RawCounter]) throws {
        for (iface, counter) in baselines.sorted(by: { $0.key < $1.key }) {
            try writeState(StateKey.rawCounter(iface), counter.encoded)
        }
    }

    // MARK: - Writes
    //
    // Each write comes in two forms. The throwing one (`writeBuckets`,
    // `writeEvents`) is for a transaction that must stop at the first
    // failure, which is what the sampler uses. The forgiving one
    // (`addBuckets`, `addEvents`) drops the error, for callers with nothing
    // to do about it. Inside a transaction even the forgiving form cannot
    // let a commit through without its rows: the failure is remembered and
    // the transaction rolls back.

    public func addEvent(ts: Int64, kind: String, detail: String) {
        try? writeEvents([LedgerEvent(ts: ts, kind: kind, detail: detail)])
    }

    public func addEvents(_ events: [LedgerEvent]) {
        try? writeEvents(events)
    }

    public func writeEvents(_ events: [LedgerEvent]) throws {
        for event in events {
            try run("INSERT INTO events(ts,kind,detail) VALUES(?,?,?);",
                    [.int(event.ts), .text(event.kind), .text(event.detail)])
        }
    }

    /// Add traffic to minute buckets. `idle` uses MIN so that a minute with any
    /// activity at all counts as active; only a wholly idle minute stays idle.
    /// `estimated` uses MAX for the mirror reason: once any part of a minute
    /// is an estimate, bytes measured into it later must not clear the mark.
    /// The wake minute after a sleep is exactly that case.
    public func addBuckets(_ buckets: [BucketDelta], ssid: String, idle: Bool) {
        try? writeBuckets(buckets, ssid: ssid, idle: idle)
    }

    public func writeBuckets(_ buckets: [BucketDelta], ssid: String, idle: Bool) throws {
        guard !buckets.isEmpty else { return }
        let sql = """
        INSERT INTO samples(minute,iface,ssid,bytes_in,bytes_out,idle,estimated) VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(minute,iface,ssid) DO UPDATE SET
            bytes_in  = bytes_in  + excluded.bytes_in,
            bytes_out = bytes_out + excluded.bytes_out,
            idle      = MIN(idle, excluded.idle),
            estimated = MAX(estimated, excluded.estimated);
        """
        for bucket in buckets {
            try run(sql, [.int(bucket.minute), .text(bucket.iface), .text(ssid),
                           .int(Int64(bitPattern: bucket.bytesIn)),
                           .int(Int64(bitPattern: bucket.bytesOut)),
                           .int(idle ? 1 : 0),
                           .int(bucket.estimated ? 1 : 0)])
        }
    }

    public func addProcBuckets(minute: Int64, deltas: [String: (bytesIn: UInt64, bytesOut: UInt64)]) {
        guard !deltas.isEmpty else { return }
        let sql = """
        INSERT INTO proc_samples(minute,proc,bytes_in,bytes_out) VALUES(?,?,?,?)
        ON CONFLICT(minute,proc) DO UPDATE SET
            bytes_in  = bytes_in  + excluded.bytes_in,
            bytes_out = bytes_out + excluded.bytes_out;
        """
        for (name, delta) in deltas where delta.bytesIn > 0 || delta.bytesOut > 0 {
            try? run(sql, [.int(minute), .text(name),
                           .int(Int64(bitPattern: delta.bytesIn)),
                           .int(Int64(bitPattern: delta.bytesOut))])
        }
    }
}
