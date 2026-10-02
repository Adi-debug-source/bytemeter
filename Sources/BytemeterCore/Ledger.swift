import Foundation

/// The last raw counter seen for an interface, and when it was seen.
public struct RawCounter: Equatable {
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var at: Int64          // unix seconds

    public init(bytesIn: UInt64, bytesOut: UInt64, at: Int64) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.at = at
    }

    public var encoded: String { "\(bytesIn),\(bytesOut),\(at)" }

    public init?(encoded: String) {
        let parts = encoded.split(separator: ",")
        guard parts.count == 3,
              let bin = UInt64(parts[0]), let bout = UInt64(parts[1]), let at = Int64(parts[2])
        else { return nil }
        self.init(bytesIn: bin, bytesOut: bout, at: at)
    }
}

/// Why there may be a gap between this reading and the previous one.
/// It changes only the event text, never the arithmetic.
public enum GapReason: String {
    case normal
    case sleep
    case relaunch
}

public struct BucketDelta: Equatable {
    public let minute: Int64
    public let iface: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    /// The bytes are real but the minute is a guess. Set when traffic from a
    /// stretch nobody watched (sleep, a relaunch, the time since a restart) is
    /// spread evenly across it, or dumped into one minute because the stretch
    /// was too long to spread. Totals count these bytes like any others; only
    /// the charts that show *when* the data went draw them differently.
    public let estimated: Bool

    public init(minute: Int64, iface: String, bytesIn: UInt64, bytesOut: UInt64, estimated: Bool = false) {
        self.minute = minute
        self.iface = iface
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.estimated = estimated
    }
}

public struct LedgerEvent: Equatable {
    public let ts: Int64
    public let kind: String
    public let detail: String

    public init(ts: Int64, kind: String, detail: String) {
        self.ts = ts
        self.kind = kind
        self.detail = detail
    }
}

public struct IngestOutcome {
    public let buckets: [BucketDelta]
    public let events: [LedgerEvent]
    public let baselines: [String: RawCounter]
}

/// The minutes one past spread covered, worked back out from its event.
public struct SpreadWindow: Equatable {
    public let iface: String
    public let firstMinute: Int64
    public let lastMinute: Int64

    public init(iface: String, firstMinute: Int64, lastMinute: Int64) {
        self.iface = iface
        self.firstMinute = firstMinute
        self.lastMinute = lastMinute
    }
}

public enum Ledger {

    /// Anything longer than this between two readings counts as a gap worth
    /// spreading rather than dumping into a single minute. Normal sampling is
    /// every 5 seconds, so this only trips on sleep, a crash or a stall.
    public static let spreadThresholdSeconds: Int64 = 90

    /// A clock jump larger than this is not believable as real elapsed time.
    /// Seven days of minutes is already 10,080 buckets, and beyond that the
    /// cost of writing rows outweighs any fidelity gained.
    public static let maxSpreadMinutes: Int64 = 7 * 24 * 60

    private static let wrap32: UInt64 = 4_294_967_296

    /// Turn a set of cumulative counter readings into minute buckets.
    ///
    /// Pure on purpose: everything it needs is passed in and everything it
    /// decides is returned, so the awkward cases can be tested without a
    /// database, a timer or a network. That includes `bootTime`, the unix
    /// second the kernel booted (see `BootClock`), or nil if it could not be
    /// read; it is only consulted when a counter goes backwards.
    public static func ingest(readings: [InterfaceReading],
                              previous: [String: RawCounter],
                              now: Int64,
                              source: CounterSource,
                              reason: GapReason,
                              bootTime: Int64?) -> IngestOutcome {
        var buckets: [BucketDelta] = []
        var events: [LedgerEvent] = []
        var baselines: [String: RawCounter] = [:]

        for reading in readings {
            let current = RawCounter(bytesIn: reading.bytesIn, bytesOut: reading.bytesOut, at: now)

            guard let prev = previous[reading.name] else {
                // First time this interface has ever been seen. Its counter is
                // cumulative since boot, and that lump has no time detail at
                // all, so it must never be recorded as traffic. Baseline only.
                baselines[reading.name] = current
                events.append(LedgerEvent(
                    ts: now, kind: "baseline",
                    detail: "\(reading.name) first seen at \(reading.bytesIn) in, \(reading.bytesOut) out. "
                          + "Counted from here; earlier traffic is not attributable to any minute."))
                continue
            }

            // Whatever happens below, the next reading is measured from this one.
            baselines[reading.name] = current

            let fellBack = reading.bytesIn < prev.bytesIn || reading.bytesOut < prev.bytesOut
            if !fellBack {
                place(iface: reading.name,
                      deltaIn: reading.bytesIn - prev.bytesIn,
                      deltaOut: reading.bytesOut - prev.bytesOut,
                      since: prev.at, now: now, reason: reason,
                      buckets: &buckets, events: &events)
                continue
            }

            let fell = "\(reading.name) counter fell from \(prev.bytesIn)/\(prev.bytesOut) to "
                     + "\(reading.bytesIn)/\(reading.bytesOut)."

            // The boot time settles what a fall means. A boot later than the
            // last reading is a restart, and a counter restarts from zero at
            // boot, so everything it now holds is real traffic since then. A
            // boot time later than now is a clock that cannot be trusted, and
            // is treated as unreadable.
            let restarted: Bool? = bootTime.flatMap { boot in boot > now ? nil : boot > prev.at }

            if restarted == true, let boot = bootTime {
                let booked = bookSinceRestart(iface: reading.name,
                                              bytesIn: reading.bytesIn, bytesOut: reading.bytesOut,
                                              boot: boot, now: now, buckets: &buckets)
                events.append(LedgerEvent(ts: now, kind: "counter_reset", detail: fell + " " + booked))
                continue
            }

            if source == .ifdata32 {
                // A 32 bit counter wraps every 4.29 GB. Treat a fall as a wrap
                // only when the previous reading really was near the ceiling,
                // otherwise it is a reset and pretending otherwise would
                // invent up to 4 GB of traffic that never happened. A known
                // restart has already been dealt with above, so it can never
                // be mistaken for a wrap.
                let nearCeiling = prev.bytesIn > wrap32 - 200_000_000 || prev.bytesOut > wrap32 - 200_000_000
                if nearCeiling {
                    let deltaIn = reading.bytesIn >= prev.bytesIn
                        ? reading.bytesIn - prev.bytesIn
                        : (wrap32 - prev.bytesIn) + reading.bytesIn
                    let deltaOut = reading.bytesOut >= prev.bytesOut
                        ? reading.bytesOut - prev.bytesOut
                        : (wrap32 - prev.bytesOut) + reading.bytesOut
                    events.append(LedgerEvent(
                        ts: now, kind: "counter_wrap",
                        detail: "\(reading.name) 32 bit counter wrapped past 4.29 GB. Difference carried across."))
                    place(iface: reading.name, deltaIn: deltaIn, deltaOut: deltaOut,
                          since: prev.at, now: now, reason: reason,
                          buckets: &buckets, events: &events)
                    continue
                }
            }

            // No restart, or no way to tell. Record nothing: without a restart
            // the new raw value is a count since the interface came back, with
            // no start time to measure it from, and writing it would show as
            // a phantom spike.
            let why = restarted == false
                ? "No restart since the last reading, so the interface itself was reset."
                : "Reboot or interface reset; the boot time could not be read to tell which."
            events.append(LedgerEvent(
                ts: now, kind: "counter_reset",
                detail: fell + " " + why + " Baseline moved, no traffic recorded for the gap."))
        }

        return IngestOutcome(buckets: buckets, events: events, baselines: baselines)
    }

    // MARK: - Placing bytes in minutes

    /// Put a delta that moved some time after `since` into minute buckets.
    private static func place(iface: String, deltaIn: UInt64, deltaOut: UInt64,
                              since: Int64, now: Int64, reason: GapReason,
                              buckets: inout [BucketDelta], events: inout [LedgerEvent]) {
        if deltaIn == 0 && deltaOut == 0 { return }

        let elapsed = max(0, now - since)
        let nowMinute = floorDiv(now, 60)
        let prevMinute = floorDiv(since, 60)
        let spanMinutes = nowMinute - prevMinute

        if elapsed <= spreadThresholdSeconds || spanMinutes <= 1 {
            // The ordinary case. A delta that straddles a minute boundary
            // lands wholly in the current minute; at a 5 second cadence that
            // smears at most 5 seconds of traffic, which no figure notices.
            buckets.append(BucketDelta(minute: nowMinute, iface: iface, bytesIn: deltaIn, bytesOut: deltaOut))
            return
        }

        if spanMinutes > maxSpreadMinutes {
            // The bytes are real, the minute is not, so it is still an estimate.
            buckets.append(BucketDelta(minute: nowMinute, iface: iface,
                                       bytesIn: deltaIn, bytesOut: deltaOut, estimated: true))
            events.append(LedgerEvent(
                ts: now, kind: "gap_too_long",
                detail: "\(iface) gap of \(elapsed) seconds is longer than \(maxSpreadMinutes) minutes. "
                      + "Recorded in one bucket rather than spread."))
            return
        }

        // A real gap: sleep, a crash, or the app was not running. The delta
        // covers the whole period, so spread it evenly over the minutes it
        // actually spans rather than claiming it all happened at once. The
        // minute of the last reading is left out: it already holds what was
        // measured up to that reading.
        buckets += spread(iface: iface, deltaIn: deltaIn, deltaOut: deltaOut,
                          firstMinute: prevMinute + 1, lastMinute: nowMinute)
        events.append(LedgerEvent(
            ts: now, kind: "gap_\(reason.rawValue)",
            detail: spreadDetail(iface: iface, elapsed: elapsed, deltaIn: deltaIn,
                                 deltaOut: deltaOut, parts: spanMinutes)))
    }

    /// After a restart the counter began again from zero, so the whole reading
    /// is traffic since boot. Returns the sentence the event uses to say how
    /// it was booked.
    private static func bookSinceRestart(iface: String, bytesIn: UInt64, bytesOut: UInt64,
                                         boot: Int64, now: Int64,
                                         buckets: inout [BucketDelta]) -> String {
        let sinceBoot = now - boot
        let nowMinute = floorDiv(now, 60)
        let bootMinute = floorDiv(boot, 60)
        // Unlike a gap, the boot minute itself is included: nothing was
        // measured in it, and traffic can start within seconds of boot.
        let parts = nowMinute - bootMinute + 1
        let opening = "The Mac restarted \(sinceBoot) seconds before this reading, so the counter began "
                    + "again from zero and all of it is traffic since the restart."

        if bytesIn == 0 && bytesOut == 0 {
            return opening + " Nothing to record yet."
        }
        if sinceBoot <= spreadThresholdSeconds {
            buckets.append(BucketDelta(minute: nowMinute, iface: iface, bytesIn: bytesIn, bytesOut: bytesOut))
            return opening + " Counted in this minute."
        }
        if parts > maxSpreadMinutes {
            buckets.append(BucketDelta(minute: nowMinute, iface: iface,
                                       bytesIn: bytesIn, bytesOut: bytesOut, estimated: true))
            return opening + " Recorded in one bucket, as the restart was more than \(maxSpreadMinutes) minutes ago."
        }
        buckets += spread(iface: iface, deltaIn: bytesIn, deltaOut: bytesOut,
                          firstMinute: bootMinute, lastMinute: nowMinute)
        return opening + " Spread evenly across \(parts) minutes from the restart, so its timing is estimated."
    }

    /// Divide a delta evenly across a run of minutes, inclusive at both ends,
    /// with the remainder from the integer division in the last one so not a
    /// byte is lost. Every row is flagged as an estimate.
    private static func spread(iface: String, deltaIn: UInt64, deltaOut: UInt64,
                               firstMinute: Int64, lastMinute: Int64) -> [BucketDelta] {
        let parts = lastMinute - firstMinute + 1
        guard parts > 0 else { return [] }
        let baseIn = deltaIn / UInt64(parts)
        let baseOut = deltaOut / UInt64(parts)
        let remainderIn = deltaIn - baseIn * UInt64(parts)
        let remainderOut = deltaOut - baseOut * UInt64(parts)

        var out: [BucketDelta] = []
        for step in 0..<parts {
            let isLast = step == parts - 1
            let bin = baseIn + (isLast ? remainderIn : 0)
            let bout = baseOut + (isLast ? remainderOut : 0)
            if bin == 0 && bout == 0 { continue }
            out.append(BucketDelta(minute: firstMinute + step, iface: iface,
                                   bytesIn: bin, bytesOut: bout, estimated: true))
        }
        return out
    }

    // MARK: - Spread events, written and read back

    /// The one place the text of a spread event is written. The schema 2
    /// migration reads it back to find rows spread before the `estimated`
    /// column existed, so writing and reading live side by side.
    static func spreadDetail(iface: String, elapsed: Int64, deltaIn: UInt64, deltaOut: UInt64, parts: Int64) -> String {
        "\(iface) gap of \(elapsed) seconds. \(deltaIn) in and \(deltaOut) out spread evenly across \(parts) minutes."
    }

    /// The minutes a past spread covered, from its event's timestamp and text.
    ///
    /// A spread event fires at the wake moment and covers the `parts` minutes
    /// ending with that one. Returns nil rather than guessing if the text is
    /// not exactly what `spreadDetail` writes, or if its minute count does not
    /// agree with its own duration, which it always does for a real event.
    public static func spreadWindow(eventTs: Int64, detail: String) -> SpreadWindow? {
        let words = detail.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count == 15,
              let elapsed = Int64(words[3]),
              let deltaIn = UInt64(words[5]),
              let deltaOut = UInt64(words[8]),
              let parts = Int64(words[13]),
              parts >= 1, parts <= maxSpreadMinutes,
              spreadDetail(iface: words[0], elapsed: elapsed, deltaIn: deltaIn,
                           deltaOut: deltaOut, parts: parts) == detail
        else { return nil }

        let wakeMinute = floorDiv(eventTs, 60)
        guard wakeMinute - floorDiv(eventTs - elapsed, 60) == parts else { return nil }
        return SpreadWindow(iface: words[0], firstMinute: wakeMinute - parts + 1, lastMinute: wakeMinute)
    }

    /// Integer division that floors towards negative infinity, so pre 1970
    /// timestamps and negative clock values cannot land in the wrong minute.
    public static func floorDiv(_ value: Int64, _ divisor: Int64) -> Int64 {
        let q = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? q - 1 : q
    }
}
