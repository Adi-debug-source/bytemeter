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

    deinit { sqlite3_close(handle) }

    // MARK: - Plumbing

    public func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw BytemeterError.sql(sql, message)
        }
    }

    public func run(_ sql: String, _ binds: [Binding] = []) throws {
        let statement = try Statement(db: handle, sql: sql)
        statement.bind(binds)
        let result = sqlite3_step(statement.handle)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw BytemeterError.sql(sql, String(cString: sqlite3_errmsg(handle)))
        }
    }

    public func query(_ sql: String, _ binds: [Binding] = [], each: (Statement) -> Void) throws {
        let statement = try Statement(db: handle, sql: sql)
        statement.bind(binds)
        while sqlite3_step(statement.handle) == SQLITE_ROW { each(statement) }
    }

    public func transaction(_ body: () throws -> Void) {
        do {
            try exec("BEGIN IMMEDIATE;")
            try body()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            FileHandle.standardError.write(Data("Bytemeter: transaction rolled back: \(error)\n".utf8))
        }
    }

    // MARK: - Schema

    private func migrate() throws {
        var version: Int64 = 0
        try query("PRAGMA user_version;") { version = $0.int(0) }

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
            PRAGMA user_version=1;
            """)
        }
    }

    // MARK: - State

    public func state(_ key: String) -> String? {
        var value: String?
        try? query("SELECT value FROM state WHERE key=?;", [.text(key)]) { value = $0.string(0) }
        return value
    }

    public func setState(_ key: String, _ value: String) {
        try? run("INSERT INTO state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
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

    public func baselines() -> [String: RawCounter] {
        var out: [String: RawCounter] = [:]
        try? query("SELECT key, value FROM state WHERE key LIKE 'raw:%';") { row in
            let iface = String(row.string(0).dropFirst(4))
            if let counter = RawCounter(encoded: row.string(1)) { out[iface] = counter }
        }
        return out
    }

    public func saveBaselines(_ baselines: [String: RawCounter]) {
        for (iface, counter) in baselines {
            setState(StateKey.rawCounter(iface), counter.encoded)
        }
    }

    // MARK: - Writes

    public func addEvent(ts: Int64, kind: String, detail: String) {
        try? run("INSERT INTO events(ts,kind,detail) VALUES(?,?,?);",
                 [.int(ts), .text(kind), .text(detail)])
    }

    public func addEvents(_ events: [LedgerEvent]) {
        for event in events { addEvent(ts: event.ts, kind: event.kind, detail: event.detail) }
    }

    /// Add traffic to minute buckets. `idle` uses MIN so that a minute with any
    /// activity at all counts as active; only a wholly idle minute stays idle.
    public func addBuckets(_ buckets: [BucketDelta], ssid: String, idle: Bool) {
        guard !buckets.isEmpty else { return }
        let sql = """
        INSERT INTO samples(minute,iface,ssid,bytes_in,bytes_out,idle) VALUES(?,?,?,?,?,?)
        ON CONFLICT(minute,iface,ssid) DO UPDATE SET
            bytes_in  = bytes_in  + excluded.bytes_in,
            bytes_out = bytes_out + excluded.bytes_out,
            idle      = MIN(idle, excluded.idle);
        """
        for bucket in buckets {
            try? run(sql, [.int(bucket.minute), .text(bucket.iface), .text(ssid),
                           .int(Int64(bitPattern: bucket.bytesIn)),
                           .int(Int64(bitPattern: bucket.bytesOut)),
                           .int(idle ? 1 : 0)])
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
