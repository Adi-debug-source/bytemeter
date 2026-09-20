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

    public init(minute: Int64, iface: String, bytesIn: UInt64, bytesOut: UInt64) {
        self.minute = minute
        self.iface = iface
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
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
    /// database, a timer or a network.
    public static func ingest(readings: [InterfaceReading],
                              previous: [String: RawCounter],
                              now: Int64,
                              source: CounterSource,
                              reason: GapReason) -> IngestOutcome {
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

            var deltaIn: UInt64 = 0
            var deltaOut: UInt64 = 0
            var didReset = false

            let fellBack = reading.bytesIn < prev.bytesIn || reading.bytesOut < prev.bytesOut

            if fellBack && source == .ifdata32 {
                // A 32 bit counter wraps every 4.29 GB. Treat a fall as a wrap
                // only when the previous reading really was near the ceiling,
                // otherwise it is a reboot and pretending otherwise would
                // invent up to 4 GB of traffic that never happened.
                let nearCeiling = prev.bytesIn > wrap32 - 200_000_000 || prev.bytesOut > wrap32 - 200_000_000
                if nearCeiling {
                    deltaIn = reading.bytesIn >= prev.bytesIn
                        ? reading.bytesIn - prev.bytesIn
                        : (wrap32 - prev.bytesIn) + reading.bytesIn
                    deltaOut = reading.bytesOut >= prev.bytesOut
                        ? reading.bytesOut - prev.bytesOut
                        : (wrap32 - prev.bytesOut) + reading.bytesOut
                    events.append(LedgerEvent(
                        ts: now, kind: "counter_wrap",
                        detail: "\(reading.name) 32 bit counter wrapped past 4.29 GB. Difference carried across."))
                } else {
                    didReset = true
                }
            } else if fellBack {
                didReset = true
            } else {
                deltaIn = reading.bytesIn - prev.bytesIn
                deltaOut = reading.bytesOut - prev.bytesOut
            }

            if didReset {
                // A reboot, or the interface was taken down and brought back.
                // Record nothing: the new raw value is a total since boot, not a
                // delta, and writing it would show as a phantom multi GB spike.
                baselines[reading.name] = current
                events.append(LedgerEvent(
                    ts: now, kind: "counter_reset",
                    detail: "\(reading.name) counter fell from \(prev.bytesIn)/\(prev.bytesOut) to "
                          + "\(reading.bytesIn)/\(reading.bytesOut). Reboot or interface reset. "
                          + "Baseline moved, no traffic recorded for the gap."))
                continue
            }

            baselines[reading.name] = current

            if deltaIn == 0 && deltaOut == 0 { continue }

            let elapsed = max(0, now - prev.at)
            let nowMinute = floorDiv(now, 60)
            let prevMinute = floorDiv(prev.at, 60)
            let spanMinutes = nowMinute - prevMinute

            if elapsed <= spreadThresholdSeconds || spanMinutes <= 1 {
                // The ordinary case. A delta that straddles a minute boundary
                // lands wholly in the current minute; at a 5 second cadence that
                // smears at most 5 seconds of traffic, which no figure notices.
                buckets.append(BucketDelta(minute: nowMinute, iface: reading.name,
                                           bytesIn: deltaIn, bytesOut: deltaOut))
                continue
            }

            if spanMinutes > maxSpreadMinutes {
                buckets.append(BucketDelta(minute: nowMinute, iface: reading.name,
                                           bytesIn: deltaIn, bytesOut: deltaOut))
                events.append(LedgerEvent(
                    ts: now, kind: "gap_too_long",
                    detail: "\(reading.name) gap of \(elapsed) seconds is longer than \(maxSpreadMinutes) minutes. "
                          + "Recorded in one bucket rather than spread."))
                continue
            }

            // A real gap: sleep, a crash, or the app was not running. The delta
            // covers the whole period, so spread it evenly over the minutes it
            // actually spans rather than claiming it all happened at once.
            let parts = spanMinutes
            let baseIn = deltaIn / UInt64(parts)
            let baseOut = deltaOut / UInt64(parts)
            let remainderIn = deltaIn - baseIn * UInt64(parts)
            let remainderOut = deltaOut - baseOut * UInt64(parts)

            for step in 0..<parts {
                let minute = prevMinute + 1 + step
                let isLast = step == parts - 1
                let bin = baseIn + (isLast ? remainderIn : 0)
                let bout = baseOut + (isLast ? remainderOut : 0)
                if bin == 0 && bout == 0 { continue }
                buckets.append(BucketDelta(minute: minute, iface: reading.name, bytesIn: bin, bytesOut: bout))
            }

            events.append(LedgerEvent(
                ts: now, kind: "gap_\(reason.rawValue)",
                detail: "\(reading.name) gap of \(elapsed) seconds. "
                      + "\(deltaIn) in and \(deltaOut) out spread evenly across \(parts) minutes."))
        }

        return IngestOutcome(buckets: buckets, events: events, baselines: baselines)
    }

    /// Integer division that floors towards negative infinity, so pre 1970
    /// timestamps and negative clock values cannot land in the wrong minute.
    public static func floorDiv(_ value: Int64, _ divisor: Int64) -> Int64 {
        let q = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? q - 1 : q
    }
}
