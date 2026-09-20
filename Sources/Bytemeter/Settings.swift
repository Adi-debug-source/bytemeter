import Foundation
import BytemeterCore

/// Preferences, cached in memory so the 5 second sampler is not querying
/// SQLite for a handful of flags on every tick. Writes go to both.
final class Settings {
    private let db: Database
    private let write: (@escaping () -> Void) -> Void
    private let lock = NSLock()

    private var _statusMode: StatusMode
    private var _liveSpeed: Bool
    private var _ssidCapture: Bool
    private var _perAppSampling: Bool
    private var _capEnabled: Bool
    private var _capBytes: Int64
    private var _cycleStartDay: Int

    /// `write` hands a closure to whichever queue owns the database.
    init(db: Database, write: @escaping (@escaping () -> Void) -> Void) {
        self.db = db
        self.write = write
        _statusMode = StatusMode(rawValue: db.state(StateKey.statusMode) ?? "") ?? .today
        _liveSpeed = db.flag(StateKey.liveSpeed, default: false)
        _ssidCapture = db.flag(StateKey.ssidCapture, default: false)
        _perAppSampling = db.flag(StateKey.perAppSampling, default: true)
        _capEnabled = db.flag(StateKey.capEnabled, default: false)
        _capBytes = db.number(StateKey.capBytes, default: 0)
        _cycleStartDay = Int(db.number(StateKey.cycleStartDay, default: 1))
    }

    private func get<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func set(_ body: () -> Void, persist key: String, value: String) {
        lock.lock(); body(); lock.unlock()
        let db = self.db
        write { db.setState(key, value) }
    }

    var statusMode: StatusMode {
        get { get { _statusMode } }
        set { set({ _statusMode = newValue }, persist: StateKey.statusMode, value: newValue.rawValue) }
    }

    var liveSpeed: Bool {
        get { get { _liveSpeed } }
        set { set({ _liveSpeed = newValue }, persist: StateKey.liveSpeed, value: newValue ? "1" : "0") }
    }

    var ssidCapture: Bool {
        get { get { _ssidCapture } }
        set { set({ _ssidCapture = newValue }, persist: StateKey.ssidCapture, value: newValue ? "1" : "0") }
    }

    var perAppSampling: Bool {
        get { get { _perAppSampling } }
        set { set({ _perAppSampling = newValue }, persist: StateKey.perAppSampling, value: newValue ? "1" : "0") }
    }

    // Cap machinery. Wired through the schema, the preferences and the progress
    // bars, and switched off. It can be turned on later without a rebuild.
    var capEnabled: Bool {
        get { get { _capEnabled } }
        set { set({ _capEnabled = newValue }, persist: StateKey.capEnabled, value: newValue ? "1" : "0") }
    }

    var capBytes: Int64 {
        get { get { _capBytes } }
        set { set({ _capBytes = newValue }, persist: StateKey.capBytes, value: String(newValue)) }
    }

    /// 1 means calendar months, which is the default. Any other day makes the
    /// month figures follow a billing cycle instead.
    var cycleStartDay: Int {
        get { get { _cycleStartDay } }
        set { set({ _cycleStartDay = newValue }, persist: StateKey.cycleStartDay, value: String(newValue)) }
    }
}
