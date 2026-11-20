import Foundation
import BytemeterCore
import BytemeterDashboard

// `swift run -c release BytemeterSelfTest --measure` times the work the app
// repeats, on a database the size a long-running install has: 90 days of
// minute rows for two interfaces, with per-app rows beside them. It checks
// nothing and is no part of the gate; it exists so a change that claims to be
// faster can show its figures before and after, from the same command.
//
// What it times is the engine's side of each job, as the app calls it:
//   - a reading: what the sampler does every 5 seconds, from the saved
//     baselines to the committed transaction, for eight interfaces, two of
//     them carrying traffic, as a Mac with Wi-Fi and unused ports has;
//   - reading the interface counters from the kernel, which comes before
//     each of those, and once a second while the live speed is on;
//   - the menu bar figure in each of its four modes, asked after every reading;
//   - a per-app write, every 30 seconds;
//   - the menu, built each time it is opened;
//   - the dashboard, from its queries to the finished page;
//   - opening the database, as at launch.
//
// Each line is the median of its runs, so one slow run does not move it. The
// app's own cost while it sits in the menu bar, its processor time and its
// memory, is measured on the running app by Scripts/measure_idle.sh.

private let measureInterfaces = ["en0", "en1", "en2", "en3", "en4", "en5", "en6", "en7"]

/// The median of `runs` timings of `body`, in microseconds. `before` runs
/// ahead of each and is not timed.
private func medianMicroseconds(runs: Int, before: () -> Void = {}, _ body: () -> Void) -> Double {
    var timings: [UInt64] = []
    timings.reserveCapacity(runs)
    for _ in 0..<runs {
        before()
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        timings.append(DispatchTime.now().uptimeNanoseconds - start)
    }
    timings.sort()
    return Double(timings[timings.count / 2]) / 1_000
}

private func line(_ label: String, _ microseconds: Double) {
    let figure = microseconds >= 10_000
        ? String(format: "%8.1f ms", microseconds / 1_000)
        : String(format: "%8.0f µs", microseconds)
    print("  " + label.padding(toLength: 46, withPad: " ", startingAt: 0) + figure)
}

/// 90 days of minute rows ending at `end`, written as the sampler writes
/// them but in few transactions, so building the fixture takes seconds.
private func fillNinetyDays(_ db: Database, end: Int64) {
    let first = end - 90 * 24 * 60
    var minute = first
    var seed: UInt64 = 20_260_920
    func next() -> UInt64 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return seed >> 33
    }
    let apps = ["Safari", "Music", "Mail", "Xcode", "backupd", "mDNSResponder", "Photos", "softwareupdated"]
    while minute < end {
        let stop = min(end, minute + 24 * 60)
        db.transaction {
            for m in minute..<stop {
                try db.writeBuckets([BucketDelta(minute: m, iface: "en0", bytesIn: 20_000 + next() % 4_000_000,
                                                 bytesOut: 2_000 + next() % 300_000)],
                                    ssid: ssidPlaceholder, idle: m % 7 == 0)
                if m % 5 == 0 {
                    try db.writeBuckets([BucketDelta(minute: m, iface: "en1", bytesIn: next() % 900_000,
                                                     bytesOut: next() % 90_000)],
                                        ssid: ssidPlaceholder, idle: false)
                }
                if m % 2 == 0 {
                    var deltas: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
                    for app in apps.prefix(Int(1 + next() % 4)) {
                        deltas[app] = (bytesIn: 1_000 + next() % 500_000, bytesOut: 100 + next() % 50_000)
                    }
                    db.addProcBuckets(minute: m, deltas: deltas)
                }
            }
        }
        minute = stop
    }
}

func runMeasurements() {
    let path = scratchFolder + "measure.db"
    let db = try! Database(path: path)
    // A fixed moment, so the ranges asked for are the same on every run.
    let nowSeconds: Int64 = 1_795_000_000
    let now = Date(timeIntervalSince1970: TimeInterval(nowSeconds))
    let nowMinute = nowSeconds / 60
    fillNinetyDays(db, end: nowMinute)
    var rows: Int64 = 0
    try? db.query("SELECT COUNT(*) FROM samples;") { rows = $0.int(0) }

    print("Bytemeter measurements, medians, on \(rows) minute rows (90 days):")

    // A reading every 5 seconds: eight interfaces, two of them moving.
    var counters = [String: (UInt64, UInt64)]()
    for name in measureInterfaces { counters[name] = (0, 0) }
    var tick: Int64 = 0
    func takeReading() {
        tick += 1
        counters["en0"] = (counters["en0"]!.0 + 48_000, counters["en0"]!.1 + 5_000)
        counters["en1"] = (counters["en1"]!.0 + 900, counters["en1"]!.1 + 300)
        let readings = measureInterfaces.map { reading($0, counters[$0]!.0, counters[$0]!.1) }
        let outcome = Ledger.ingest(readings: readings, previous: db.baselines(), now: nowSeconds + tick * 5,
                                    reason: .normal, bootTime: 1_789_000_000, bootSession: "A")
        db.transaction {
            try db.writeReading(outcome, ssid: ssidPlaceholder, idle: false, reason: .normal, counterSource: .mib64)
        }
    }
    takeReading()   // the first sight of each interface only baselines
    line("a reading, every 5 seconds", medianMicroseconds(runs: 2_000) { takeReading() })

    // The figure as the app asks for it: once after each reading, at that
    // reading's moment, so the clock moves on between one and the next.
    // This Mac's own interfaces, so the figure depends on how many it has.
    line("reading the interface counters", medianMicroseconds(runs: 300) { _ = InterfaceMonitor.read() })

    let aggregator = Aggregator(db: db, cal: london)
    for mode in StatusMode.allCases {
        line("the menu bar figure, \(mode.label.lowercased())",
             medianMicroseconds(runs: mode == .allTime ? 100 : 500, before: takeReading) {
            _ = Headlines.figure(for: mode, aggregator: aggregator,
                                 now: Date(timeIntervalSince1970: TimeInterval(nowSeconds + tick * 5)))
        })
    }

    var appTick: Int64 = 0
    let appDeltas: [String: (bytesIn: UInt64, bytesOut: UInt64)] = Dictionary(
        uniqueKeysWithValues: (0..<25).map { ("app\($0)", (bytesIn: UInt64(1_000 + $0), bytesOut: UInt64(100 + $0))) })
    line("a per-app write, every 30 seconds", medianMicroseconds(runs: 500) {
        appTick += 1
        db.addProcBuckets(minute: nowMinute + 10 + appTick, deltas: appDeltas)
    })

    line("the menu, each time it opens", medianMicroseconds(runs: 15) {
        _ = MenuSnapshot(aggregator: aggregator, now: now)
    })

    let options = DashboardData.Options(ssidCapture: false, perAppSampling: true, capEnabled: true,
                                        capBytes: 200_000_000_000)
    line("the dashboard, queries and page", medianMicroseconds(runs: 9) {
        _ = DashboardGenerator.html(DashboardData(aggregator: aggregator, options: options, now: now))
    })

    line("opening the database", medianMicroseconds(runs: 25) {
        _ = try! Database(path: path)
    })
}
