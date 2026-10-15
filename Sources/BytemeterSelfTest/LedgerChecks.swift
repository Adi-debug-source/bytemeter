import Foundation
import BytemeterCore

// Checks for Ledger.ingest, which turns two counter readings into traffic:
// an ordinary delta, first sight, resets and restarts, 32 bit wraps, gaps
// spread across sleep and downtime, the counter source, which interfaces
// count, a clock that is set wrong, and the events read back in plain words.

// MARK: - The ordinary case

func checkOrdinaryReadingBooksItsDelta() {
    let previous = ["en0": RawCounter(bytesIn: 1_000, bytesOut: 500, at: 600)]
    let outcome = Ledger.ingest(readings: [reading("en0", 4_000, 800)],
                                previous: previous, now: 605, reason: .normal, bootTime: nil)
    expect(outcome.buckets.count, 1, "normal delta writes one bucket")
    expect(outcome.buckets.first?.bytesIn, 3_000, "normal delta down")
    expect(outcome.buckets.first?.bytesOut, 300, "normal delta up")
    expect(outcome.buckets.first?.minute, 10, "bucket lands in the current minute")
    expect(outcome.baselines["en0"]?.bytesIn, 4_000, "baseline moves forward")
}

// MARK: - First sight is a baseline, never traffic

func checkFirstSightIsABaseline() {
    let outcome = Ledger.ingest(readings: [reading("en0", 4_700_000_000, 85_000_000)],
                                previous: [:], now: 600, reason: .relaunch, bootTime: nil)
    check(outcome.buckets.isEmpty, "first sight of an interface must record no traffic")
    expect(outcome.events.first?.kind, "baseline", "first sight logs a baseline event")
    expect(outcome.baselines["en0"]?.bytesIn, 4_700_000_000, "first sight sets the baseline")
}

// MARK: - A reboot must not become a phantom multi GB spike

func checkResetBooksNoSpike() {
    let previous = ["en0": RawCounter(bytesIn: 4_700_000_000, bytesOut: 85_000_000, at: 600)]
    let outcome = Ledger.ingest(readings: [reading("en0", 12_000, 3_000)],
                                previous: previous, now: 900, reason: .relaunch, bootTime: nil)
    check(outcome.buckets.isEmpty, "a counter reset must not write any traffic")
    expect(outcome.events.first?.kind, "counter_reset", "a reset is logged as an event")
    expect(outcome.baselines["en0"]?.bytesIn, 12_000, "a reset moves the baseline to the new value")
}

// MARK: - 32 bit wrap versus reboot

func checkThirtyTwoBitWrapIsCarried() {
    let nearCeiling: UInt64 = 4_294_967_296 - 1_000
    let previous = ["en0": RawCounter(bytesIn: nearCeiling, bytesOut: 10, at: 600)]
    let outcome = Ledger.ingest(readings: [reading32("en0", 500, 20)],
                                previous: previous, now: 605, reason: .normal, bootTime: nil)
    expect(outcome.buckets.count, 1, "a wrap still records traffic")
    expect(outcome.buckets.first?.bytesIn, 1_500, "wrap carries 1,000 to the ceiling plus 500 after it")
    expect(outcome.events.first?.kind, "counter_wrap", "a wrap is logged as a wrap")
}

func checkFarFallIsAResetNotAWrap() {
    let previous = ["en0": RawCounter(bytesIn: 500_000, bytesOut: 400, at: 600)]
    let outcome = Ledger.ingest(readings: [reading32("en0", 100, 10)],
                                previous: previous, now: 605, reason: .normal, bootTime: nil)
    check(outcome.buckets.isEmpty, "a fall far from the 32 bit ceiling is a reboot, not a wrap")
    expect(outcome.events.first?.kind, "counter_reset", "that case is logged as a reset")
}

// MARK: - Sleep gaps are spread, and nothing is lost to rounding

func checkSleepGapIsSpreadWhole() {
    let previous = ["en0": RawCounter(bytesIn: 1_000, bytesOut: 100, at: 600)]   // minute 10
    let now: Int64 = 600 + 3_600                                                 // minute 70
    let outcome = Ledger.ingest(readings: [reading("en0", 1_000 + 100_003, 100 + 61)],
                                previous: previous, now: now, reason: .sleep, bootTime: nil)
    expect(outcome.buckets.count, 60, "one bucket per elapsed minute")
    expect(outcome.buckets.first?.minute, 11, "spreading starts the minute after the last reading")
    expect(outcome.buckets.last?.minute, 70, "spreading ends at the current minute")
    let totalIn = outcome.buckets.reduce(UInt64(0)) { $0 + $1.bytesIn }
    let totalOut = outcome.buckets.reduce(UInt64(0)) { $0 + $1.bytesOut }
    expect(totalIn, 100_003, "spreading must not lose the remainder, down")
    expect(totalOut, 61, "spreading must not lose the remainder, up")
    expect(outcome.events.first?.kind, "gap_sleep", "a sleep gap is recorded honestly as a gap")
}

// MARK: - Traffic while Bytemeter was not running is recovered

func checkRelaunchRecoversTheGap() {
    let previous = ["en0": RawCounter(bytesIn: 1_000, bytesOut: 0, at: 600)]
    let outcome = Ledger.ingest(readings: [reading("en0", 601_000, 0)],
                                previous: previous, now: 600 + 600, reason: .relaunch, bootTime: nil)
    let totalIn = outcome.buckets.reduce(UInt64(0)) { $0 + $1.bytesIn }
    expect(totalIn, 600_000, "a relaunch recovers the traffic from while it was down")
    expect(outcome.events.first?.kind, "gap_relaunch", "the downtime is logged")
}

// MARK: - Interface filtering

func checkOnlyPhysicalInterfacesCount() {
    for name in ["en0", "en1", "en12"] {
        check(InterfaceMonitor.isPhysical(name), "\(name) should be counted")
    }
    for name in ["lo0", "utun0", "utun5", "awdl0", "llw0", "bridge0", "gif0", "stf0", "ap1", "anpi0", "nan0", "en"] {
        check(!InterfaceMonitor.isPhysical(name), "\(name) must not be counted")
    }
}

// MARK: - Estimated rows: only spread minutes carry the mark

func checkOnlySpreadRowsAreEstimated() {
    let measured = Ledger.ingest(readings: [reading("en0", 4_000, 800)],
                                 previous: ["en0": RawCounter(bytesIn: 1_000, bytesOut: 500, at: 600)],
                                 now: 605, reason: .normal, bootTime: nil)
    check(measured.buckets.allSatisfy { !$0.estimated }, "a measured delta is not marked estimated")

    let previous = ["en0": RawCounter(bytesIn: 1_000, bytesOut: 100, at: 600)]
    let slept = Ledger.ingest(readings: [reading("en0", 1_000 + 100_003, 100 + 61)],
                              previous: previous, now: 600 + 3_600, reason: .sleep, bootTime: nil)
    check(!slept.buckets.isEmpty && slept.buckets.allSatisfy(\.estimated), "every spread row is marked estimated")

    // The event the spread writes must lead back to exactly the minutes it filled.
    let window = slept.events.first.flatMap { Ledger.spreadWindow(eventTs: $0.ts, detail: $0.detail) }
    expect(window, SpreadWindow(iface: "en0", firstMinute: 11, lastMinute: 70),
           "a spread event reads back to the minutes it covered")
    expect(window?.firstMinute, slept.buckets.first?.minute, "the read back window starts at the first spread row")
    expect(window?.lastMinute, slept.buckets.last?.minute, "the read back window ends at the wake minute")
    expect(Ledger.spreadWindow(eventTs: 4_200, detail: "en0 gap of lots. Spread somehow."), nil,
           "an unreadable spread event gives no window rather than a guess")
    expect(Ledger.spreadWindow(eventTs: 4_200,
                               detail: "en0 gap of 3600 seconds. 5 in and 5 out spread evenly across 9 minutes."), nil,
           "a spread event whose minutes disagree with its own duration gives no window")

    let tooLong = Ledger.ingest(readings: [reading("en0", 2_000, 200)], previous: previous,
                                now: 600 + (Ledger.maxSpreadMinutes + 10) * 60,
                                reason: .sleep, bootTime: nil)
    expect(tooLong.buckets.count, 1, "a gap too long to spread lands in one minute")
    check(tooLong.buckets.first?.estimated == true, "that minute is marked estimated: right bytes, wrong minute")
    expect(tooLong.events.first?.kind, "gap_too_long", "and it is logged as too long")
}

// MARK: - A restart books the bytes since boot; a bare interface reset does not

func checkRestartBooksBytesSinceBoot() {
    let previous = ["en0": RawCounter(bytesIn: 9_653_780_865, bytesOut: 858_256_858, at: 1_000_000)]

    let soon = Ledger.ingest(readings: [reading("en0", 9_071, 22_190)], previous: previous,
                             now: 1_000_537, reason: .relaunch, bootTime: 1_000_500)
    expect(soon.buckets.count, 1, "a restart moments ago books its bytes in one minute")
    expect(soon.buckets.first?.bytesIn, 9_071, "everything since the restart is counted, down")
    expect(soon.buckets.first?.bytesOut, 22_190, "everything since the restart is counted, up")
    expect(soon.buckets.first?.minute, Ledger.floorDiv(1_000_537, 60), "in the current minute")
    check(soon.buckets.first?.estimated == false, "a restart within the threshold is not an estimate")
    expect(soon.events.first?.kind, "counter_reset", "the fall is still logged as a reset")
    check(soon.events.first?.detail.contains("restarted 37 seconds before") == true,
          "the event says it was a restart, got: \(soon.events.first?.detail ?? "")")
    expect(soon.baselines["en0"]?.bytesIn, 9_071, "the baseline moves to the new reading")

    let boot: Int64 = 1_000_500
    let later = Ledger.ingest(readings: [reading("en0", 6_000_007, 600_011)], previous: previous,
                              now: boot + 3_600, reason: .relaunch, bootTime: boot)
    expect(later.buckets.first?.minute, Ledger.floorDiv(boot, 60), "a restart long ago spreads from the boot minute")
    expect(later.buckets.last?.minute, Ledger.floorDiv(boot + 3_600, 60), "to the current minute")
    expect(later.buckets.reduce(UInt64(0)) { $0 + $1.bytesIn }, 6_000_007, "the spread since boot loses nothing, down")
    expect(later.buckets.reduce(UInt64(0)) { $0 + $1.bytesOut }, 600_011, "the spread since boot loses nothing, up")
    check(later.buckets.allSatisfy(\.estimated), "bytes spread since a restart are marked estimated")
    check(later.events.first?.detail.contains("Spread evenly across 61 minutes from the restart") == true,
          "the event says how the restart was booked, got: \(later.events.first?.detail ?? "")")

    let interfaceOnly = Ledger.ingest(readings: [reading("en0", 9_071, 22_190)], previous: previous,
                                      now: 1_000_537, reason: .normal, bootTime: 900_000)
    check(interfaceOnly.buckets.isEmpty, "an interface reset without a restart records nothing")
    check(interfaceOnly.events.first?.detail.contains("interface itself was reset") == true,
          "the event says it was the interface, got: \(interfaceOnly.events.first?.detail ?? "")")

    let unknown = Ledger.ingest(readings: [reading("en0", 9_071, 22_190)], previous: previous,
                                now: 1_000_537, reason: .normal, bootTime: nil)
    check(unknown.buckets.isEmpty, "with no boot time a fall records nothing, as before")
    check(unknown.events.first?.detail.contains("could not be read") == true,
          "the event says the boot time was unreadable, got: \(unknown.events.first?.detail ?? "")")

    let future = Ledger.ingest(readings: [reading("en0", 9_071, 22_190)], previous: previous,
                               now: 1_000_537, reason: .normal, bootTime: 2_000_000)
    check(future.buckets.isEmpty, "a boot time later than now is not trusted, so nothing is booked")

    let wrapPrevious = ["en0": RawCounter(bytesIn: 4_294_967_296 - 1_000, bytesOut: 10, at: 1_000_000)]
    let rebootNearCeiling = Ledger.ingest(readings: [reading32("en0", 500, 20)], previous: wrapPrevious,
                                          now: 1_000_537, reason: .normal, bootTime: 1_000_500)
    expect(rebootNearCeiling.buckets.first?.bytesIn, 500, "a known restart is never mistaken for a 32 bit wrap")

    let firstSight = Ledger.ingest(readings: [reading("en0", 4_700_000_000, 85_000_000)], previous: [:],
                                   now: 1_000_537, reason: .relaunch, bootTime: 1_000_500)
    check(firstSight.buckets.isEmpty, "first sight stays baseline only, even with a boot time known")

    let booted = BootClock.bootTime()
    check(booted != nil, "this Mac's boot time can be read")
    check((booted ?? 0) > 0 && (booted ?? .max) <= Int64(Date().timeIntervalSince1970),
          "and it is in the past")
}

// MARK: - An idle interface says nothing across a restart

func checkIdleInterfaceSaysNothingAcrossRestart() {
    // Unused ports read zero all their lives. A restart sends every counter
    // back to zero, so zero before and zero after is no change at all, and
    // must not add a reset line per interface at every boot.
    let boot: Int64 = 1_000_500
    let idleBefore = ["en1": RawCounter(bytesIn: 0, bytesOut: 0, at: 1_000_000, bootSession: "A")]
    let quiet = Ledger.ingest(readings: [reading("en1", 0, 0)], previous: idleBefore, now: 1_000_537,
                              reason: .relaunch, bootTime: boot, bootSession: "B")
    check(quiet.events.isEmpty,
          "an interface at zero before and after a restart logs nothing, got: \(quiet.events.map(\.kind))")
    check(quiet.buckets.isEmpty, "and books nothing")
    expect(quiet.baselines["en1"]?.bootSession, "B", "its baseline still moves to the new boot session")
    expect(quiet.baselines["en1"]?.at, 1_000_537, "and to the time of the new reading")

    let quietNoBootTime = Ledger.ingest(readings: [reading("en1", 0, 0)], previous: idleBefore, now: 1_003_600,
                                        reason: .normal, bootTime: nil, bootSession: "B")
    check(quietNoBootTime.events.isEmpty, "the same when the boot time cannot be read")

    let quietByBootTime = Ledger.ingest(readings: [reading("en1", 0, 0)],
                                        previous: ["en1": RawCounter(bytesIn: 0, bytesOut: 0, at: 1_000_000)],
                                        now: 1_000_537, reason: .relaunch, bootTime: boot)
    check(quietByBootTime.events.isEmpty, "the same when the boot time, not the session, shows the restart")

    // Beside a busy interface, only the busy one is logged.
    var busyAndIdle = idleBefore
    busyAndIdle["en0"] = RawCounter(bytesIn: 5_000_000, bytesOut: 400_000, at: 1_000_000, bootSession: "A")
    let both = Ledger.ingest(readings: [reading("en0", 9_071, 22_190), reading("en1", 0, 0)],
                             previous: busyAndIdle, now: 1_000_537, reason: .relaunch,
                             bootTime: boot, bootSession: "B")
    expect(both.events.filter { $0.kind == "counter_reset" }.count, 1, "beside a busy interface, one reset is logged")
    check(both.events.first?.detail.hasPrefix("en0 ") == true,
          "and it is the busy one's, got: \(both.events.first?.detail ?? "")")

    // Zero on one side only is a real change, and is still logged.
    let woke = Ledger.ingest(readings: [reading("en1", 500, 0)], previous: idleBefore, now: 1_000_537,
                             reason: .relaunch, bootTime: boot, bootSession: "B")
    expect(woke.events.first?.kind, "counter_reset", "zero before a restart and traffic after it is still logged")
    expect(woke.buckets.reduce(UInt64(0)) { $0 + $1.bytesIn }, 500, "and its traffic since the restart is booked")
    let fellToZero = Ledger.ingest(readings: [reading("en1", 0, 0)],
                                   previous: ["en1": RawCounter(bytesIn: 100, bytesOut: 0, at: 1_000_000, bootSession: "A")],
                                   now: 1_000_537, reason: .relaunch, bootTime: boot, bootSession: "B")
    expect(fellToZero.events.first?.kind, "counter_reset", "traffic before a restart and zero after it is still logged")
    let upOnly = Ledger.ingest(readings: [reading("en1", 0, 0)],
                               previous: ["en1": RawCounter(bytesIn: 0, bytesOut: 64, at: 1_000_000, bootSession: "A")],
                               now: 1_000_537, reason: .relaunch, bootTime: boot, bootSession: "B")
    expect(upOnly.events.first?.kind, "counter_reset", "so is a counter that had only sent before the restart")

    // The next ordinary reading measures from the quiet restart's baseline.
    let after = Ledger.ingest(readings: [reading("en1", 1_000, 0)], previous: quiet.baselines, now: 1_000_542,
                              reason: .normal, bootTime: boot, bootSession: "B")
    expect(after.buckets.reduce(UInt64(0)) { $0 + $1.bytesIn }, 1_000, "after it, traffic is counted from zero as normal")
    check(after.events.isEmpty, "with nothing logged")
}

// MARK: - A restart is decided first, whether or not the counter fell

func checkRestartIsDecidedFirst() {
    let previous = ["en0": RawCounter(bytesIn: 1_000_000, bytesOut: 100_000, at: 1_000_000)]
    let climbed = reading("en0", 5_000_000, 400_000)          // already past the old value

    let byBootTime = Ledger.ingest(readings: [climbed], previous: previous, now: 1_000_537,
                                   reason: .relaunch, bootTime: 1_000_500)
    expect(byBootTime.buckets.first?.bytesIn, 5_000_000,
           "a restart where the counter has passed the old value books the full reading, not the difference")
    expect(byBootTime.buckets.first?.bytesOut, 400_000, "and the full reading up")
    check(byBootTime.events.first?.detail.contains("went from 1000000/100000 to 5000000/400000. The Mac restarted") == true,
          "the event says the counter went up across a restart, got: \(byBootTime.events.first?.detail ?? "")")

    let normal = Ledger.ingest(readings: [climbed], previous: previous, now: 1_000_005,
                               reason: .normal, bootTime: 900_000)
    expect(normal.buckets.first?.bytesIn, 4_000_000, "a normal sample with the boot before the last reading takes the difference")
    check(normal.events.isEmpty, "and logs nothing")

    // With boot session ids on both sides, the id decides.
    let sessionA = ["en0": RawCounter(bytesIn: 1_000_000, bytesOut: 100_000, at: 1_000_000, bootSession: "A")]
    let newSession = Ledger.ingest(readings: [climbed], previous: sessionA, now: 1_000_537,
                                   reason: .relaunch, bootTime: 1_000_500, bootSession: "B")
    expect(newSession.buckets.first?.bytesIn, 5_000_000, "a new boot session books the full reading")
    expect(newSession.baselines["en0"]?.bootSession, "B", "the new baseline carries the current boot session")

    // Setting the clock forward moves the kernel's boot time with it, past
    // the last reading. The session is unchanged, so it is not a restart, and
    // the traffic since boot must not be counted a second time.
    let clockSet = Ledger.ingest(readings: [climbed], previous: sessionA, now: 1_086_405,
                                 reason: .normal, bootTime: 1_000_500, bootSession: "A")
    expect(clockSet.buckets.reduce(UInt64(0)) { $0 + $1.bytesIn }, 4_000_000,
           "a clock set forward is not a restart: only the difference is counted")
    check(!clockSet.events.contains { $0.kind == "counter_reset" }, "and no reset is logged")

    // Restarted by the id, but no usable boot time: placed across the whole gap.
    let unplaced = Ledger.ingest(readings: [climbed], previous: sessionA, now: 1_003_600,
                                 reason: .normal, bootTime: nil, bootSession: "B")
    expect(unplaced.buckets.reduce(UInt64(0)) { $0 + $1.bytesIn }, 5_000_000,
           "a restart the boot time cannot place still books the full reading")
    check(unplaced.buckets.allSatisfy(\.estimated) && unplaced.buckets.first?.minute == Ledger.floorDiv(1_000_000, 60) + 1,
          "spread, as an estimate, from the minute after the last reading")
    check(unplaced.events.first?.detail.contains("could not say when") == true,
          "the event says the time was unknown, got: \(unplaced.events.first?.detail ?? "")")

    let fellSameSession = Ledger.ingest(readings: [reading("en0", 9_071, 22_190)], previous: sessionA,
                                        now: 1_000_537, reason: .normal,
                                        bootTime: 1_000_500, bootSession: "A")
    check(fellSameSession.buckets.isEmpty, "a fall in the same boot session is an interface reset and books nothing")

    expect(RawCounter(encoded: "1,2,3,7DBE9237-C7FF"), RawCounter(bytesIn: 1, bytesOut: 2, at: 3, bootSession: "7DBE9237-C7FF"),
           "a baseline with a boot session reads back")
    expect(RawCounter(encoded: "1,2,3"), RawCounter(bytesIn: 1, bytesOut: 2, at: 3),
           "a baseline saved before sessions were kept still reads, with no session")
    expect(RawCounter(bytesIn: 1, bytesOut: 2, at: 3, bootSession: "X").encoded, "1,2,3,X", "the session is stored after the time")
    expect(RawCounter(encoded: "1,2"), nil, "a malformed baseline is refused")
    check(BootClock.bootSession() != nil, "this Mac's boot session id can be read")
}

// MARK: - The counter source is per reading, and a switch is never arithmetic

func checkCounterSourceIsPerReading() {
    let tenGB: UInt64 = 10_000_000_000
    let low32 = tenGB % 4_294_967_296                     // the 32 bit view of the same counter

    // A 64 bit baseline, then the 32 bit view of it in the same boot. This used to trap, before anything was written.
    let prev64 = ["en0": RawCounter(bytesIn: tenGB, bytesOut: 50_000_000, at: 1_790_000_000, bootSession: "A", source: .mib64)]
    let down = Ledger.ingest(readings: [reading32("en0", low32, 50_000_100)], previous: prev64, now: 1_790_000_005,
                             reason: .normal, bootTime: 1_789_000_000, bootSession: "A")
    check(down.buckets.isEmpty, "a switch from the 64 bit to the 32 bit counter books nothing")
    expect(down.events.map(\.kind), ["counter_source"], "and says why")
    expect(down.baselines["en0"]?.source, .ifdata32, "the new baseline records the 32 bit source")
    expect(down.baselines["en0"]?.bytesIn, low32, "and measures from the new reading")
    let after = Ledger.ingest(readings: [reading32("en0", low32 + 7_000, 50_000_200)], previous: down.baselines,
                              now: 1_790_000_010, reason: .normal, bootTime: 1_789_000_000, bootSession: "A")
    expect(after.buckets.first?.bytesIn, 7_000, "after a switch the next reading measures normally")

    // The reverse used to book 8.59 GB in 5 seconds.
    let prev32 = ["en0": RawCounter(bytesIn: low32, bytesOut: 50_000_000, at: 1_790_000_000, bootSession: "A", source: .ifdata32)]
    let up = Ledger.ingest(readings: [reading("en0", tenGB + 50_000, 50_000_100)], previous: prev32, now: 1_790_000_005,
                           reason: .normal, bootTime: 1_789_000_000, bootSession: "A")
    check(up.buckets.isEmpty, "a switch back to the 64 bit counter books no phantom gigabytes")
    check(up.events.first?.detail.contains("came from the 32 bit getifaddrs counter and this one from the 64 bit interface MIB") == true,
          "the event names both counters, got: \(up.events.first?.detail ?? "")")

    // A baseline saved before sources were kept, above the 32 bit ceiling: the crash case on upgrade.
    let legacy = ["en0": RawCounter(bytesIn: tenGB, bytesOut: 50_000_000, at: 1_790_000_000, bootSession: "A")]
    let legacyDown = Ledger.ingest(readings: [reading32("en0", low32, 50_000_100)], previous: legacy, now: 1_790_000_005,
                                   reason: .normal, bootTime: 1_789_000_000, bootSession: "A")
    check(legacyDown.buckets.isEmpty && legacyDown.events.first?.kind == "counter_source",
          "a legacy baseline above 4.29 GB is known to be 64 bit, so a 32 bit reading after it books nothing")

    // A fall is a wrap only if every direction that fell was near the ceiling.
    let wrapPrev = ["en0": RawCounter(bytesIn: 4_294_967_296 - 1_000, bytesOut: 10, at: 600, source: .ifdata32)]
    expect(Ledger.ingest(readings: [reading32("en0", 500, 20)], previous: wrapPrev, now: 605, reason: .normal,
                         bootTime: nil).buckets.first?.bytesIn, 1_500, "a 32 bit wrap is still carried across")
    let mixedPrev = ["en0": RawCounter(bytesIn: 4_294_967_296 - 1_000, bytesOut: 900_000, at: 600, source: .ifdata32)]
    check(Ledger.ingest(readings: [reading32("en0", 500, 10)], previous: mixedPrev, now: 605, reason: .normal,
                        bootTime: nil).buckets.isEmpty,
          "an upload counter that fell far from the ceiling makes it a reset, not 4.29 GB of invented upload")
    let corrupt = ["en0": RawCounter(bytesIn: UInt64.max, bytesOut: UInt64.max, at: 600, source: .ifdata32)]
    check(Ledger.ingest(readings: [reading32("en0", 5, 5)], previous: corrupt, now: 605, reason: .normal,
                        bootTime: nil).buckets.isEmpty, "a 32 bit baseline that does not fit in 32 bits is not a wrap")

    // The stored form.
    expect(RawCounter(bytesIn: 1, bytesOut: 2, at: 3, bootSession: "X", source: .ifdata32).encoded, "1,2,3,X,ifdata32",
           "the source is stored after the session")
    expect(RawCounter(bytesIn: 1, bytesOut: 2, at: 3, source: .mib64).encoded, "1,2,3,,mib64",
           "with no session the field is left empty, so the source keeps its place")
    expect(RawCounter(encoded: "1,2,3,,mib64"), RawCounter(bytesIn: 1, bytesOut: 2, at: 3, source: .mib64),
           "a baseline with a source and no session reads back")
    expect(RawCounter(encoded: "1,2,3,X,ifdata32"), RawCounter(bytesIn: 1, bytesOut: 2, at: 3, bootSession: "X", source: .ifdata32),
           "a baseline with both reads back")
    check(RawCounter(encoded: "1,2,3,X,quantum").map { $0.source == nil && $0.bootSession == "X" } == true,
          "a source this build does not know reads as unknown rather than losing the baseline")
    expect(RawCounter(encoded: "1,2,3,X,mib64,9"), nil, "an unknown sixth field is refused")
    expect(RawCounter(encoded: "1,2,3,X,mib64,behind,9"), nil, "seven fields are refused")
    let heldCounter = RawCounter(bytesIn: 1, bytesOut: 2, at: 3, clockBehind: true)
    expect(heldCounter.encoded, "1,2,3,,,behind", "a held baseline keeps every field's place")
    expect(RawCounter(encoded: heldCounter.encoded), heldCounter, "and reads back held, so a hold survives a relaunch")

    // Through the database, and the hint for baselines saved by earlier versions.
    let db = makeDatabase()
    db.saveBaselines(["en0": RawCounter(bytesIn: 5, bytesOut: 6, at: 7, bootSession: "S", source: .ifdata32)])
    expect(db.baselines()["en0"]?.source, .ifdata32, "a baseline's source round trips through the database")
    let old = makeDatabase()
    old.saveBaselines(["en0": RawCounter(bytesIn: low32, bytesOut: 6, at: 7), "en1": RawCounter(bytesIn: tenGB, bytesOut: 6, at: 7)])
    expect(old.baselines()["en0"]?.source, nil, "with no record of the old source a legacy baseline stays unknown")
    old.setState(StateKey.counterSource, CounterSource.ifdata32.rawValue)
    expect(old.baselines()["en0"]?.source, .ifdata32, "a legacy baseline that fits 32 bits takes the old snapshot's 32 bit source")
    expect(old.baselines()["en1"]?.source, .mib64, "a legacy value above 4.29 GB can only be 64 bit")
    old.setState(StateKey.counterSource, CounterSource.mib64.rawValue)
    expect(old.baselines()["en0"]?.source, .mib64, "if the old snapshot was 64 bit, so was every baseline")
    let oldReading = Ledger.ingest(readings: [reading("en0", tenGB, 6)], previous: {
        old.setState(StateKey.counterSource, CounterSource.ifdata32.rawValue); return old.baselines() }(),
                                   now: 1_790_000_005, reason: .normal, bootTime: nil)
    check(oldReading.buckets.isEmpty, "a legacy 32 bit baseline then a 64 bit reading books no phantom gigabytes")

    // Labelled one interface at a time.
    var fallbackCalls = 0
    let snapshot = InterfaceMonitor.assemble(names: ["en1", "en0"], mib: { $0 == "en0" ? (100, 200) : nil },
                                             fallback: { fallbackCalls += 1; return ["en1": (3, 4), "en0": (1, 2)] })
    expect(snapshot.readings.map(\.name), ["en0", "en1"], "interfaces are read in name order")
    expect(snapshot.readings.map(\.source), [.mib64, .ifdata32], "each reading carries the counter it came from")
    expect(snapshot.readings.map(\.bytesIn), [100, 3], "en0 from the MIB, en1 from the fallback")
    expect(snapshot.source, .ifdata32, "the snapshot's summary says a fallback was used")
    let allMIB = InterfaceMonitor.assemble(names: ["en0", "en1"], mib: { _ in (1, 1) },
                                           fallback: { fallbackCalls += 1; return [:] })
    check(allMIB.source == .mib64 && fallbackCalls == 1, "with the MIB answering for everything the fallback is never asked")
    check(InterfaceMonitor.read().readings.allSatisfy { $0.source == .mib64 }, "on this Mac every interface reads from the 64 bit MIB")

    // No input can trap: random and extreme counters, times, sessions and sources.
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next() -> UInt64 { seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return seed >> 1 }
    func pick<T>(_ options: [T]) -> T { options[Int(next() % UInt64(options.count))] }
    let counts: [UInt64] = [0, 1, 199_999_999, 4_094_967_297, 4_294_967_295, 4_294_967_296, 4_294_967_297,
                            9_223_372_036_854_775_807, UInt64.max - 1, UInt64.max]
    let times: [Int64] = [Int64.min, Int64.min + 1, -61, -1, 0, 1, 600, 1_790_000_000, 1_790_000_095, Int64.max - 1, Int64.max]
    func count() -> UInt64 { next() % 3 == 0 ? next() : pick(counts) }
    var survived = 0
    var timeWentBack = 0
    for _ in 0..<20_000 {
        let prev = RawCounter(bytesIn: count(), bytesOut: count(), at: pick(times), bootSession: pick(["A", "B", nil]),
                              source: pick([nil, .mib64, .ifdata32]))
        let current = InterfaceReading(name: "en0", bytesIn: count(), bytesOut: count(), source: pick([.mib64, .ifdata32]))
        let outcome = Ledger.ingest(readings: [current], previous: ["en0": prev], now: pick(times),
                                    reason: pick([.normal, .sleep, .relaunch]),
                                    bootTime: pick([nil] + times.map { Optional($0) }), bootSession: pick(["A", "B", nil]))
        survived += outcome.baselines.count
        if let saved = outcome.baselines["en0"], saved.at < prev.at { timeWentBack += 1 }
    }
    expect(survived, 20_000, "twenty thousand awkward readings, extremes included, and not one traps")
    expect(timeWentBack, 0, "and not one saves a baseline time earlier than the last")
    check(Ledger.spreadWindow(eventTs: Int64.min,
                              detail: "en0 gap of 9223372036854775807 seconds. 1 in and 1 out spread evenly across 2 minutes.") == nil,
          "a spread event whose times overflow gives no window rather than a trap")
}

// MARK: - A clock set backwards books nothing in the past

func checkClockSetBackwardsBooksNothingInThePast() {
    let lastMinute = Ledger.floorDiv(1_790_000_000, 60)
    let prev = ["en0": RawCounter(bytesIn: 1_000, bytesOut: 100, at: 1_790_000_000, bootSession: "A", source: .mib64)]
    let y2001: Int64 = 978_307_200
    let back = Ledger.ingest(readings: [reading("en0", 6_000, 600)], previous: prev, now: y2001, reason: .normal,
                             bootTime: nil, bootSession: "A")
    expect(back.buckets.map(\.minute), [lastMinute], "a reading under a clock set back to 2001 books in the last reading's minute")
    expect(back.buckets.first?.bytesIn, 5_000, "and loses no byte")
    expect(back.events.map(\.kind), ["clock_backwards"], "and says the clock went back")
    let restartedBack = Ledger.ingest(readings: [reading("en0", 6_000, 600)], previous: prev, now: y2001, reason: .normal,
                                      bootTime: nil, bootSession: "B")
    check(!restartedBack.buckets.isEmpty && restartedBack.buckets.allSatisfy { $0.minute >= lastMinute },
          "a restart found while the clock reads 2001 books nothing before the last reading either")
    let nudgedPrev = ["en0": RawCounter(bytesIn: 1_000, bytesOut: 100, at: 1_790_000_030, bootSession: "A", source: .mib64)]
    let nudged = Ledger.ingest(readings: [reading("en0", 6_000, 600)], previous: nudgedPrev, now: 1_790_000_028,
                               reason: .normal, bootTime: nil, bootSession: "A")
    check(nudged.buckets.first?.minute == lastMinute && nudged.baselines["en0"]?.at == 1_790_000_030
          && nudged.baselines["en0"]?.clockBehind == true,
          "a clock nudged back two seconds books in the same minute and keeps the later time")
    let db = makeDatabase()
    db.addBuckets(back.buckets, ssid: ssidPlaceholder, idle: false)
    expect(Aggregator(db: db, cal: london).earliestMinute(), lastMinute, "so All time still starts at the first real minute")
}

// MARK: - A clock that stays wrong books nothing in the past

func checkClockThatStaysWrongBooksNothingInThePast() {
    // The reviewer's case: three readings under a clock set to 1 January 2001, then put right.
    let goodMinute = Ledger.floorDiv(1_790_000_000, 60)
    let db = makeDatabase()
    db.saveBaselines(["en0": RawCounter(bytesIn: 1_000, bytesOut: 0, at: 1_790_000_000, bootSession: "A", source: .mib64)])
    var raw: UInt64 = 1_000
    var minutes: [[Int64]] = []
    var kinds: [String] = []
    var savedTimes: [Int64] = [1_790_000_000]
    for t: Int64 in [978_350_400, 978_350_405, 978_350_410, 1_790_000_020] {
        raw += 10_000
        let out = Ledger.ingest(readings: [reading("en0", raw, 0)], previous: db.baselines(), now: t, reason: .normal,
                                bootTime: 978_000_000, bootSession: "A")
        check(db.transaction {
            try db.writeReading(out, ssid: ssidPlaceholder, idle: false, reason: .normal, counterSource: nil)
        }, "the reading at \(t) is written")
        minutes.append(out.buckets.map(\.minute))
        kinds += out.events.map(\.kind)
        savedTimes.append(db.baselines()["en0"]?.at ?? 0)
    }
    expect(minutes, [[goodMinute], [goodMinute], [goodMinute], [Ledger.floorDiv(1_790_000_020, 60)]],
           "every reading while the clock reads 2001 books in the last good minute, and the first after it is put right at its own")
    check(zip(savedTimes, savedTimes.dropFirst()).allSatisfy { $0 <= $1 }, "the saved baseline time never goes backwards, got \(savedTimes)")
    expect(kinds, ["clock_backwards", "clock_caught_up"], "the hold is logged once where it begins and once where it ends")
    expect(sumIn(db), 40_000, "every byte is booked once")
    let all = Aggregator(db: db, cal: london).allTime(now: Date(timeIntervalSince1970: 1_790_000_030))
    expect(all.since, BytemeterCalendar.date(fromMinute: goodMinute), "All time still starts at the real first minute")
    check(all.days < 1, "and has counted under a day, not 9,394, got \(all.days)")

    // A clock that jumps forward for a reading, then back: every byte once, nothing before the last good minute.
    var baselines = ["en0": RawCounter(bytesIn: 0, bytesOut: 0, at: 1_790_000_000, bootSession: "A", source: .mib64)]
    var counter: UInt64 = 0
    var booked: UInt64 = 0
    var earliest = Int64.max
    var times: [Int64] = [1_790_000_000]
    for t: Int64 in [1_790_000_005, 1_790_000_010, 2_230_000_000, 1_790_000_015, 1_790_000_020, 1_790_000_025] {
        counter += 7_777
        let out = Ledger.ingest(readings: [reading("en0", counter, counter)], previous: baselines, now: t, reason: .normal,
                                bootTime: nil, bootSession: "A")
        booked += out.buckets.reduce(UInt64(0)) { $0 + $1.bytesIn }
        earliest = min(earliest, out.buckets.map(\.minute).min() ?? .max)
        for (name, raw) in out.baselines { baselines[name] = raw }
        times.append(baselines["en0"]?.at ?? 0)
    }
    expect(booked, counter, "a clock that jumps forward and back books every byte exactly once")
    check(earliest >= goodMinute, "and nothing before the last good minute")
    check(zip(times, times.dropFirst()).allSatisfy { $0 <= $1 }, "and its saved times never go backwards, got \(times)")
}

// MARK: - Recent events read in plain words, and the stored text stays as it was

func checkEventsReadInPlainWords() {
    func worded(_ event: LedgerEvent?) -> (label: String, text: String) {
        EventWording.describe(kind: event?.kind ?? "", detail: event?.detail ?? "")
    }
    func ingest(_ previous: [String: RawCounter], _ current: InterfaceReading, now: Int64, reason: GapReason = .normal,
                bootTime: Int64? = 900_000, bootSession: String? = nil) -> LedgerEvent? {
        Ledger.ingest(readings: [current], previous: previous, now: now, reason: reason, bootTime: bootTime,
                      bootSession: bootSession).events.first
    }

    // Every kind the ledger writes, made by the ledger itself, so a change to
    // its wording that the labels rely on is caught here.
    let at: Int64 = 1_000_000
    let plain = ["en0": RawCounter(bytesIn: 9_653_780_865, bytesOut: 858_256_858, at: at)]
    let fromLedger: [(LedgerEvent?, String)] = [
        (ingest([:], reading("en0", 5_000, 500), now: at), "New interface"),
        (ingest(plain, reading("en0", 9_071, 22_190), now: at + 537, bootTime: at + 500), "Restart"),
        (ingest(["en0": RawCounter(bytesIn: 9_000, bytesOut: 900, at: at, bootSession: "A")],
                reading("en0", 100, 10), now: at + 537, bootTime: nil, bootSession: "B"), "Restart"),
        (ingest(plain, reading("en0", 9_071, 22_190), now: at + 537), "Interface reset"),
        (ingest(plain, reading("en0", 9_071, 22_190), now: at + 537, bootTime: nil), "Counter reset"),
        (ingest(["en0": RawCounter(bytesIn: 4_294_967_296 - 1_000, bytesOut: 10, at: at)], reading32("en0", 500, 20),
                now: at + 5), "Counter wrapped"),
        (ingest(["en0": RawCounter(bytesIn: 10_000_000_000, bytesOut: 50, at: at, source: .mib64)],
                reading32("en0", 1_410_065_408, 60), now: at + 5), "Counter changed"),
        (ingest(["en0": RawCounter(bytesIn: 1_000, bytesOut: 100, at: at)], reading("en0", 2_000, 200),
                now: at - 3_600), "Clock went back"),
        (ingest(["en0": RawCounter(bytesIn: 1_000, bytesOut: 100, at: at, clockBehind: true)], reading("en0", 2_000, 200),
                now: at + 5), "Clock caught up"),
        (ingest(["en0": RawCounter(bytesIn: 1_000, bytesOut: 100, at: at)], reading("en0", 2_000, 200),
                now: at + 8 * 86_400), "Long gap"),
    ]
    for (event, label) in fromLedger {
        expect(worded(event).label, label, "\(event?.kind ?? "no event") reads as \(label)")
        expect(worded(event).text, event?.detail ?? "", "and \(label) keeps its stored text")
    }
    check(fromLedger[4].0?.detail.contains("could not be read to tell which") == true,
          "the reset labelled neither way is the one whose text says it could not tell a restart from a reset")
    expect(EventWording.describe(kind: "counter_reset", detail: "en0 counter fell. Baseline moved.").label, "Counter reset",
           "and so is a reset in words this build does not know")

    // The kinds written elsewhere, and ones this build does not know.
    for (kind, label) in [("seed", "Counting began"), ("prune", "Tidy up"), ("estimated_backfill", "Upgrade"),
                          ("gap_sleep", "Asleep"), ("gap_relaunch", "Not running"), ("gap_normal", "Gap"),
                          ("something_new", "Something new"), ("a_kind_from_later", "A kind from later"),
                          ("plain", "Plain"), ("", "")] {
        expect(EventWording.describe(kind: kind, detail: "As stored.").label, label, "\(kind) reads as \(label)")
    }

    // A real spread, as the ledger writes it, reads as a sentence; the text
    // stored is unchanged, so the migration still finds the minutes it covers.
    let before = ["en0": RawCounter(bytesIn: 1_000_000, bytesOut: 100_000, at: 1_790_000_000)]
    let woke = reading("en0", 1_000_000 + 478_343_847, 100_000 + 68_291_553)
    let sleep = ingest(before, woke, now: 1_790_026_148, reason: .sleep)
    expect(worded(sleep).label, "Asleep", "a night's sleep is labelled Asleep")
    expect(worded(sleep).text, "en0: 7 h 16 min asleep. 478 MB down and 68.3 MB up, spread evenly across the gap.",
           "and reads as a sentence, with the gap to the nearest minute")
    check(sleep.map { Ledger.spreadWindow(eventTs: $0.ts, detail: $0.detail) != nil } == true,
          "while its stored text still reads back for the migration")
    expect(worded(ingest(before, woke, now: 1_790_026_148, reason: .relaunch)).text,
           "en0: 7 h 16 min while Bytemeter was not running. 478 MB down and 68.3 MB up, spread evenly across the gap.",
           "a relaunch says Bytemeter was not running")
    expect(worded(ingest(before, woke, now: 1_790_002_700)).text,
           "en0: 45 min between two readings. 478 MB down and 68.3 MB up, spread evenly across the gap.",
           "an ordinary gap says it fell between two readings")

    // Durations, to the nearest minute under a day and the nearest hour from a day.
    func spread(_ seconds: Int64) -> String {
        EventWording.describe(kind: "gap_sleep", detail: "en1 gap of \(seconds) seconds. 1000 in and 10 out spread "
                                  + "evenly across \(max(1, min(seconds / 60, 10_080))) minutes.").text
    }
    for (seconds, duration) in [(10_800, "3 h"), (190_800, "2 days 5 h"), (3_580, "1 h"), (86_380, "1 day"),
                                (88_199, "1 day"), (88_200, "1 day 1 h"), (26_129, "7 h 15 min"), (91, "2 min"),
                                (20, "1 min"), (604_800, "7 days")] as [(Int64, String)] {
        expect(spread(seconds), "en1: \(duration) asleep. 1.0 kB down and 10 B up, spread evenly across the gap.",
               "\(seconds) seconds reads \(duration)")
    }

    // Anything that does not read back exactly keeps its stored text.
    let edited = (sleep?.detail ?? "") + " Edited."
    expect(EventWording.describe(kind: "gap_sleep", detail: edited).text, edited, "a gap's text with more on it is shown as stored")
    expect(EventWording.describe(kind: "gap_sleep", detail: edited).label, "Asleep", "under its label all the same")
    let negative = "en0 gap of -5 seconds. 1000 in and 10 out spread evenly across 2 minutes."
    expect(EventWording.describe(kind: "gap_normal", detail: negative).text, negative, "so is a gap of negative seconds")
    let unknownReason = sleep?.detail ?? ""
    expect(EventWording.describe(kind: "gap_holiday", detail: unknownReason).text, unknownReason,
           "and a gap of a kind this build does not know, however well its text reads")
    expect(EventWording.describe(kind: "something_new", detail: "Whatever it said.").text, "Whatever it said.",
           "an unknown kind keeps its stored text")
}

