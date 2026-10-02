import Foundation
import BytemeterCore

/// Reads the interface counters, turns them into minute buckets and writes them
/// down. One process does the lot: because the counters are cumulative and the
/// last raw reading is persisted after every sample, a crash and relaunch loses
/// nothing, so a separate collector daemon would buy nothing.
final class Sampler {

    static let sampleInterval: TimeInterval = 5
    static let processInterval: TimeInterval = 30
    static let rateInterval: TimeInterval = 1

    private let db: Database
    private let settings: Settings
    let queue: DispatchQueue
    private let processQueue = DispatchQueue(label: "io.github.adi-debug-source.bytemeter.nettop", qos: .utility)

    private var sampleTimer: DispatchSourceTimer?
    private var processTimer: DispatchSourceTimer?
    private var rateTimer: DispatchSourceTimer?

    private let nettop = NettopSampler()

    /// Whether the Mac is asleep and why the next reading may follow a gap.
    /// Touched only on `queue`, like the database, so the notifications from
    /// the main thread and the timer's readings never race.
    private let gate = SleepGate()

    /// The rate timer's last reading. Touched only on `processQueue`, where
    /// the rate timer runs; resets from elsewhere are sent there.
    private var lastRateReading: (bytesIn: UInt64, bytesOut: UInt64, at: Date)?

    var onSample: (() -> Void)?
    var onRate: ((Double, Double) -> Void)?

    init(db: Database, settings: Settings, queue: DispatchQueue) {
        self.db = db
        self.settings = settings
        self.queue = queue
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            self?.recordSeedIfNeeded()
            self?.runMaintenanceIfDue()
        }
        sampleNow()

        let sampler = DispatchSource.makeTimerSource(queue: queue)
        sampler.schedule(deadline: .now() + Self.sampleInterval, repeating: Self.sampleInterval, leeway: .milliseconds(500))
        sampler.setEventHandler { [weak self] in self?.takeSample() }
        sampler.resume()
        sampleTimer = sampler

        let processes = DispatchSource.makeTimerSource(queue: processQueue)
        processes.schedule(deadline: .now() + 3, repeating: Self.processInterval, leeway: .seconds(2))
        processes.setEventHandler { [weak self] in self?.takeProcessSample() }
        processes.resume()
        processTimer = processes

        updateRateTimer()
    }

    func sampleNow() {
        queue.async { [weak self] in self?.takeSample() }
    }

    /// Live speed is a separate toggle, so its timer only exists while it is on.
    /// Off costs nothing at all.
    func updateRateTimer() {
        rateTimer?.cancel()
        rateTimer = nil
        processQueue.async { [weak self] in self?.lastRateReading = nil }
        guard settings.liveSpeed else {
            onRate?(0, 0)
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: processQueue)
        timer.schedule(deadline: .now() + Self.rateInterval, repeating: Self.rateInterval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.takeRateReading() }
        timer.resume()
        rateTimer = timer
    }

    // MARK: - Sleep and wake

    /// Called on the main thread from the will-sleep notification. Waits for
    /// the last reading, so it is written before the Mac goes to sleep rather
    /// than on waking, when it would measure the sleep as ordinary time.
    func noteSleep() {
        queue.sync { gate.enterSleep { takeSample() } }
    }

    /// Called on the main thread from the did-wake notification.
    func noteWake() {
        queue.async { [weak self] in
            guard let self else { return }
            self.gate.wake { self.takeSample() }
        }
        processQueue.async { [weak self] in self?.lastRateReading = nil }
    }

    // MARK: - Sampling

    /// Runs on `queue` only.
    private func takeSample() {
        guard let reason = gate.reasonForReading else { return }
        let snapshot = InterfaceMonitor.read()
        guard !snapshot.readings.isEmpty else { return }

        let now = Int64(Date().timeIntervalSince1970)
        let idle = IdleMonitor.isIdle()
        let ssid = SSIDProvider.currentSSID(enabled: settings.ssidCapture)

        let previous = db.baselines()
        let outcome = Ledger.ingest(readings: snapshot.readings,
                                    previous: previous,
                                    now: now,
                                    reason: reason,
                                    bootTime: BootClock.bootTime(),
                                    bootSession: BootClock.bootSession())

        // All of it or none of it. If any write fails, the baselines stay
        // where they were, so the next reading measures from them and the
        // bytes of this one are counted then rather than lost. The gap label
        // is kept for that reading too.
        let written = db.transaction {
            try db.writeBuckets(outcome.buckets, ssid: ssid, idle: idle)
            try db.writeBaselines(outcome.baselines)
            try db.writeEvents(outcome.events)
            try db.writeState(StateKey.counterSource, snapshot.source.rawValue)
        }
        if written { gate.readingWritten() }

        DispatchQueue.main.async { [weak self] in self?.onSample?() }
    }

    /// Runs on `processQueue`. The sleep check is asked of `queue`, which
    /// owns it; nothing on `queue` ever waits for `processQueue`.
    private func takeProcessSample() {
        guard settings.perAppSampling, !queue.sync(execute: { gate.asleep }) else { return }
        let deltas = nettop.sampleDeltas()
        guard !deltas.isEmpty else { return }
        let minute = BytemeterCalendar.minute(from: Date())
        queue.async { [weak self] in
            self?.db.addProcBuckets(minute: minute, deltas: deltas)
        }
    }

    /// The live rate only. It never writes to the database and never touches the
    /// bucket baselines, so it cannot disturb the figures; it just reads the same
    /// cumulative counters a second apart.
    private func takeRateReading() {
        let snapshot = InterfaceMonitor.read()
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        for reading in snapshot.readings {
            totalIn &+= reading.bytesIn
            totalOut &+= reading.bytesOut
        }
        let now = Date()
        defer { lastRateReading = (totalIn, totalOut, now) }
        guard let last = lastRateReading else { return }

        let elapsed = now.timeIntervalSince(last.at)
        guard elapsed > 0.1 else { return }
        // A fall means a reboot or an interface coming and going. Show nothing
        // rather than a nonsense spike.
        guard totalIn >= last.bytesIn, totalOut >= last.bytesOut else { return }

        let rateIn = Double(totalIn - last.bytesIn) / elapsed
        let rateOut = Double(totalOut - last.bytesOut) / elapsed
        DispatchQueue.main.async { [weak self] in self?.onRate?(rateIn, rateOut) }
    }

    // MARK: - Housekeeping

    /// One events row recording what the interfaces had already carried before
    /// Bytemeter existed. Deliberately not in `samples`: it is a lump with no time
    /// detail, and mixing it in would corrupt every hourly figure.
    private func recordSeedIfNeeded() {
        guard db.state(StateKey.seedRecorded) == nil else { return }
        let snapshot = InterfaceMonitor.read()
        let parts = snapshot.readings
            .map { "\($0.name) \($0.bytesIn) in, \($0.bytesOut) out" }
            .joined(separator: "; ")
        let seed = LedgerEvent(ts: Int64(Date().timeIntervalSince1970), kind: "seed",
                               detail: "Since boot before Bytemeter started counting: \(parts). "
                                     + "Counter source \(snapshot.source.rawValue). "
                                     + "Recorded as a lump with no time detail, and deliberately not counted in any total.")
        // The event and the flag together, so a failed write is tried again at the next launch.
        db.transaction {
            try db.writeEvents([seed])
            try db.writeState(StateKey.seedRecorded, "1")
        }
    }

    /// A prune that fails is logged and left for the next check, 6 hours on.
    private func runMaintenanceIfDue() {
        do {
            try Maintenance.runIfDue(db: db, now: Date())
        } catch {
            FileHandle.standardError.write(Data("Bytemeter: the tidy up failed and was rolled back: \(error)\n".utf8))
        }
    }

    func runMaintenanceCheck() {
        queue.async { [weak self] in self?.runMaintenanceIfDue() }
    }
}
