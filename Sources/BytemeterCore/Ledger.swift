import Foundation

/// The last raw counter seen for an interface, when it was seen, in which
/// boot of the Mac, and from which counter.
public struct RawCounter: Equatable {
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var at: Int64          // unix seconds
    /// The kernel's boot session id at the time, if it could be read. Nil for
    /// a baseline saved before ids were kept.
    public var bootSession: String?
    /// The counter the values came from. Nil for a baseline saved before
    /// sources were kept; see `Ledger.ingest` for how that is read.
    public var source: CounterSource?
    /// True when the clock read earlier than `at` at this reading, so `at` is
    /// the last good time held over rather than the clock's. See `Ledger.ingest`.
    public var clockBehind: Bool

    public init(bytesIn: UInt64, bytesOut: UInt64, at: Int64, bootSession: String? = nil,
                source: CounterSource? = nil, clockBehind: Bool = false) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.at = at
        self.bootSession = bootSession
        self.source = source
        self.clockBehind = clockBehind
    }

    /// "bytesIn,bytesOut,unixSeconds", then ",bootSession" when known, then
    /// ",source" when known, then ",behind" while the clock is behind. A field
    /// with nothing to say is left empty rather than dropped when a later one
    /// follows, so the positions never shift.
    public var encoded: String {
        var text = "\(bytesIn),\(bytesOut),\(at)"
        if bootSession != nil || source != nil || clockBehind { text += "," + (bootSession ?? "") }
        if source != nil || clockBehind { text += "," + (source?.rawValue ?? "") }
        if clockBehind { text += ",behind" }
        return text
    }

    /// Reads every form, so baselines saved by earlier versions still load.
    /// A source this build does not know reads as unknown, not as a refusal,
    /// so a newer build's baseline is not thrown away. A sixth field is either
    /// "behind" or empty; anything else is refused.
    public init?(encoded: String) {
        let parts = encoded.split(separator: ",", omittingEmptySubsequences: false)
        guard (3...6).contains(parts.count),
              let bin = UInt64(parts[0]), let bout = UInt64(parts[1]), let at = Int64(parts[2])
        else { return nil }
        if parts.count == 6 && !(parts[5].isEmpty || parts[5] == "behind") { return nil }
        let session = parts.count >= 4 && !parts[3].isEmpty ? String(parts[3]) : nil
        let source = parts.count >= 5 ? CounterSource(rawValue: String(parts[4])) : nil
        self.init(bytesIn: bin, bytesOut: bout, at: at, bootSession: session, source: source,
                  clockBehind: parts.count == 6 && parts[5] == "behind")
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
    private static let max32: UInt64 = 4_294_967_295
    /// How close to the 32 bit ceiling a previous value must be for a fall to
    /// count as a wrap rather than a reset.
    private static let wrapMargin: UInt64 = 200_000_000

    /// Turn a set of cumulative counter readings into minute buckets.
    ///
    /// Pure on purpose: everything it needs is passed in and everything it
    /// decides is returned, so the awkward cases can be tested without a
    /// database, a timer or a network. That includes what is known about the
    /// current boot (see `BootClock`): `bootTime`, the unix second the kernel
    /// booted, and `bootSession`, its boot session id, each nil if it could
    /// not be read. Together they decide whether the Mac has restarted since
    /// the last reading. Each reading says which counter it came from; see
    /// `InterfaceReading.source`.
    ///
    /// No input can make it trap. Every subtraction below is either guarded
    /// by a comparison on the line before it or saturates.
    public static func ingest(readings: [InterfaceReading],
                              previous: [String: RawCounter],
                              now: Int64,
                              reason: GapReason,
                              bootTime: Int64?,
                              bootSession: String? = nil) -> IngestOutcome {
        var buckets: [BucketDelta] = []
        var events: [LedgerEvent] = []
        var baselines: [String: RawCounter] = [:]

        for reading in readings {
            guard let prev = previous[reading.name] else {
                // First time this interface has ever been seen. Its counter is
                // cumulative since boot, and that lump has no time detail at
                // all, so it must never be recorded as traffic. Baseline only.
                baselines[reading.name] = RawCounter(bytesIn: reading.bytesIn, bytesOut: reading.bytesOut, at: now,
                                                     bootSession: bootSession, source: reading.source)
                events.append(LedgerEvent(
                    ts: now, kind: "baseline",
                    detail: "\(reading.name) first seen at \(reading.bytesIn) in, \(reading.bytesOut) out. "
                          + "Counted from here; earlier traffic is not attributable to any minute."))
                continue
            }

            // Whatever happens below, the next reading is measured from this
            // one, and the time saved with it never goes backwards. While the
            // clock reads earlier than the last reading, the last reading's
            // time is kept: every reading under the wrong clock then books in
            // that minute, not in the past, and when the clock is put right
            // the next reading measures from it as normal. Each byte is still
            // booked once, because the counters move on with every reading;
            // only the minute is held. The events mark where a hold begins
            // and ends, once each, not at every reading in between.
            let behind = now < prev.at
            baselines[reading.name] = RawCounter(bytesIn: reading.bytesIn, bytesOut: reading.bytesOut,
                                                 at: behind ? prev.at : now, bootSession: bootSession,
                                                 source: reading.source, clockBehind: behind)
            if behind && !prev.clockBehind {
                events.append(LedgerEvent(
                    ts: now, kind: "clock_backwards",
                    detail: "\(reading.name) reading is \(clampedElapsed(since: now, now: prev.at)) seconds earlier than "
                          + "the last one, so the clock went back. Until it catches up, traffic is booked in the last "
                          + "reading's minute rather than in the past."))
            } else if !behind && prev.clockBehind {
                events.append(LedgerEvent(
                    ts: now, kind: "clock_caught_up",
                    detail: "\(reading.name) the clock has caught up with the last good reading's time, so traffic is "
                          + "booked at the clock's time again."))
            }

            let fellBack = reading.bytesIn < prev.bytesIn || reading.bytesOut < prev.bytesOut
            let change = "\(reading.name) counter \(fellBack ? "fell" : "went") from \(prev.bytesIn)/\(prev.bytesOut) "
                       + "to \(reading.bytesIn)/\(reading.bytesOut)."

            // Has the Mac restarted since the last reading? Asked first, of
            // every reading: a counter restarts from zero at boot, so after a
            // restart everything it holds is traffic since then, and taking
            // `current - prev` would be wrong whether or not it has already
            // climbed back past the old value.
            //
            // The boot session id answers it exactly, because it changes at a
            // boot and at nothing else. The boot time is the fallback, for a
            // baseline saved before ids were kept: a boot later than the last
            // reading is a restart. That rule leans on the wall clock, and the
            // kernel moves its boot time when the clock is set, so setting the
            // clock forward would look like a restart and count everything
            // since boot a second time. Hence the id first. A boot time later
            // than now is a clock that cannot be trusted, and is unreadable.
            let restarted: Bool?
            if let then = prev.bootSession, let session = bootSession {
                restarted = then != session
            } else {
                restarted = bootTime.flatMap { boot in boot > now ? nil : boot > prev.at }
            }

            if restarted == true {
                if let boot = bootTime, boot > prev.at, boot <= now {
                    let booked = bookSinceRestart(iface: reading.name,
                                                  bytesIn: reading.bytesIn, bytesOut: reading.bytesOut,
                                                  boot: boot, now: now, buckets: &buckets)
                    events.append(LedgerEvent(ts: now, kind: "counter_reset", detail: change + " " + booked))
                } else {
                    // The id says it restarted but the boot time cannot say
                    // when, so the traffic since boot is placed across the
                    // whole gap since the last reading, which certainly holds it.
                    events.append(LedgerEvent(
                        ts: now, kind: "counter_reset",
                        detail: change + " The Mac restarted since the last reading, so the counter began again "
                              + "from zero and all of it is traffic since then. The boot time could not say "
                              + "when, so it is placed across the whole gap."))
                    place(iface: reading.name, deltaIn: reading.bytesIn, deltaOut: reading.bytesOut,
                          since: prev.at, now: now, reason: .relaunch,
                          buckets: &buckets, events: &events)
                }
                continue
            }

            // Was the last value read from the same counter? The 32 bit
            // counter is the 64 bit one cut short, so once an interface has
            // carried 4.29 GB the two disagree by a multiple of that, and a
            // difference across the switch is either a fall that is not a
            // wrap or a jump of gigabytes that never happened. The values
            // cannot be compared, so measure from this reading and book
            // nothing for the seconds since the last.
            let prevSource = prev.source ?? assumedSource(of: prev, current: reading.source)
            if prevSource != reading.source {
                events.append(LedgerEvent(
                    ts: now, kind: "counter_source",
                    detail: change + " The last value came from \(prevSource.phrase) and this one from "
                          + "\(reading.source.phrase), which cannot be compared. Baseline moved, no traffic "
                          + "recorded for the \(clampedElapsed(since: prev.at, now: now)) seconds since the last reading."))
                continue
            }

            if !fellBack {
                place(iface: reading.name,
                      deltaIn: reading.bytesIn - prev.bytesIn,
                      deltaOut: reading.bytesOut - prev.bytesOut,
                      since: prev.at, now: now, reason: reason,
                      buckets: &buckets, events: &events)
                continue
            }

            // A 32 bit counter wraps every 4.29 GB. A fall counts as a wrap
            // only when both values are 32 bit and every direction that fell
            // was near the ceiling; anything else is a reset, and pretending
            // otherwise would invent up to 4 GB of traffic that never
            // happened. A known restart has already been dealt with above, so
            // it can never be mistaken for a wrap.
            if reading.source == .ifdata32,
               let deltaIn = wrapDelta(from: prev.bytesIn, to: reading.bytesIn),
               let deltaOut = wrapDelta(from: prev.bytesOut, to: reading.bytesOut) {
                events.append(LedgerEvent(
                    ts: now, kind: "counter_wrap",
                    detail: "\(reading.name) 32 bit counter wrapped past 4.29 GB. Difference carried across."))
                place(iface: reading.name, deltaIn: deltaIn, deltaOut: deltaOut,
                      since: prev.at, now: now, reason: reason,
                      buckets: &buckets, events: &events)
                continue
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
                detail: change + " " + why + " Baseline moved, no traffic recorded for the gap."))
        }

        return IngestOutcome(buckets: buckets, events: events, baselines: baselines)
    }

    // MARK: - Counter arithmetic

    /// The source of a baseline saved before sources were kept. A value above
    /// the 32 bit ceiling can only have come from the 64 bit counter. Below
    /// it, the baseline is taken to match the reading, which is what earlier
    /// versions assumed; `Database.baselines()` narrows this first where the
    /// old database recorded which counter it last used.
    static func assumedSource(of prev: RawCounter, current: CounterSource) -> CounterSource {
        prev.bytesIn > max32 || prev.bytesOut > max32 ? .mib64 : current
    }

    /// The bytes between two readings of one 32 bit direction, carried across
    /// a wrap. Nil when a fall is not a believable wrap: the previous value
    /// was not near the ceiling, or either value does not fit in 32 bits, in
    /// which case the subtraction from the ceiling would not mean anything.
    static func wrapDelta(from prev: UInt64, to value: UInt64) -> UInt64? {
        if value >= prev { return value - prev }
        guard prev <= max32, value <= max32, prev > wrap32 - wrapMargin else { return nil }
        return (wrap32 - prev) + value      // at most 2^32 + 2^32, far inside UInt64
    }

    /// `now - since` in seconds, never negative and never overflowing, even
    /// for a corrupt baseline time.
    static func clampedElapsed(since: Int64, now: Int64) -> Int64 {
        guard now > since else { return 0 }
        let (difference, overflow) = now.subtractingReportingOverflow(since)
        return overflow ? Int64.max : difference
    }

    // MARK: - Placing bytes in minutes

    /// Put a delta that moved some time after `since` into minute buckets.
    ///
    /// Never earlier than the minute of the last reading. A clock set
    /// backwards, by hand or by a bad time server, would otherwise book the
    /// bytes in a minute that has already been and gone, years ago if the
    /// clock was far enough out, and that minute would then stand as the
    /// start of All time and of Month by month for good. So a reading whose
    /// time is before the last one books at the last one's minute, and
    /// `ingest` keeps that time in the baseline until the clock catches up.
    private static func place(iface: String, deltaIn: UInt64, deltaOut: UInt64,
                              since: Int64, now: Int64, reason: GapReason,
                              buckets: inout [BucketDelta], events: inout [LedgerEvent]) {
        if deltaIn == 0 && deltaOut == 0 { return }

        let elapsed = clampedElapsed(since: since, now: now)
        let nowMinute = floorDiv(now, 60)
        let prevMinute = floorDiv(since, 60)
        let spanMinutes = nowMinute - prevMinute     // each side is at most Int64.max / 60, so no overflow

        if nowMinute < prevMinute {
            buckets.append(BucketDelta(minute: prevMinute, iface: iface, bytesIn: deltaIn, bytesOut: deltaOut))
            return
        }

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
        let sinceBoot = clampedElapsed(since: boot, now: now)
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
        let (start, overflow) = eventTs.subtractingReportingOverflow(elapsed)
        guard elapsed >= 0, !overflow, wakeMinute - floorDiv(start, 60) == parts else { return nil }
        return SpreadWindow(iface: words[0], firstMinute: wakeMinute - parts + 1, lastMinute: wakeMinute)
    }

    /// Integer division that floors towards negative infinity, so pre 1970
    /// timestamps and negative clock values cannot land in the wrong minute.
    public static func floorDiv(_ value: Int64, _ divisor: Int64) -> Int64 {
        let q = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? q - 1 : q
    }
}
