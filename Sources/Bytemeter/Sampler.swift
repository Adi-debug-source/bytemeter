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
    private var nextReason: GapReason = .relaunch
    private var asleep = false

    /// Only touched by the rate timer, and only while live speed is on.
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
        lastRateReading = nil
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

    func noteSleep() {
        asleep = true
        sampleNow()
    }

    func noteWake() {
        asleep = false
        nextReason = .sleep
        lastRateReading = nil
        sampleNow()
    }

    // MARK: - Sampling

    private func takeSample() {
        guard !asleep else { return }
        let snapshot = InterfaceMonitor.read()
        guard !snapshot.readings.isEmpty else { return }

        let now = Int64(Date().timeIntervalSince1970)
        let idle = IdleMonitor.isIdle()
        let ssid = SSIDProvider.currentSSID(enabled: settings.ssidCapture)
        let reason = nextReason
        nextReason = .normal

        let previous = db.baselines()
        let outcome = Ledger.ingest(readings: snapshot.readings,
                                    previous: previous,
                                    now: now,
                                    source: snapshot.source,
                                    reason: reason,
                                    bootTime: BootClock.bootTime(),
                                    bootSession: BootClock.bootSession())

        db.transaction {
            db.addBuckets(outcome.buckets, ssid: ssid, idle: idle)
            db.saveBaselines(outcome.baselines)
            db.addEvents(outcome.events)
        }
        db.setState(StateKey.counterSource, snapshot.source.rawValue)

        DispatchQueue.main.async { [weak self] in self?.onSample?() }
    }

    private func takeProcessSample() {
        guard settings.perAppSampling, !asleep else { return }
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
        db.addEvent(ts: Int64(Date().timeIntervalSince1970), kind: "seed",
                    detail: "Since boot before Bytemeter started counting: \(parts). "
                          + "Counter source \(snapshot.source.rawValue). "
                          + "Recorded as a lump with no time detail, and deliberately not counted in any total.")
        db.setState(StateKey.seedRecorded, "1")
    }

    private func runMaintenanceIfDue() {
        let now = Date()
        let last = db.number(StateKey.lastMaintenance, default: 0)
        guard Int64(now.timeIntervalSince1970) - last > 24 * 3600 else { return }
        Maintenance.prune(db: db, now: now)
        db.setState(StateKey.lastMaintenance, String(Int64(now.timeIntervalSince1970)))
    }

    func runMaintenanceCheck() {
        queue.async { [weak self] in self?.runMaintenanceIfDue() }
    }
}
