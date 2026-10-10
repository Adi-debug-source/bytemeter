import Foundation

/// The arithmetic behind the per-app figures: cumulative totals from
/// `nettop` in, bytes used since the previous call out. Running `nettop` is
/// the app's job (see NettopSampler); this part is pure, so the self-test
/// can check it.
public struct ProcessTally {

    /// Cumulative totals from the previous call, keyed by "name.pid".
    private var previous: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]

    public init() {}

    /// One run's output as cumulative totals keyed by "name.pid". Each row
    /// reads "name.pid,bytes_in,bytes_out,"; the header, whose first field
    /// is empty, and any line that does not hold a name and two numbers are
    /// skipped.
    public static func parse(_ output: String) -> [String: (bytesIn: UInt64, bytesOut: UInt64)] {
        var current: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let key = String(fields[0])
            guard !key.isEmpty,
                  let bytesIn = UInt64(fields[1].trimmingCharacters(in: .whitespaces)),
                  let bytesOut = UInt64(fields[2].trimmingCharacters(in: .whitespaces))
            else { continue }
            current[key] = (bytesIn, bytesOut)
        }
        return current
    }

    /// Returns bytes used per process since the previous call, keyed by process
    /// name with the pid stripped. An empty run leaves the previous totals as
    /// they were.
    public mutating func deltas(_ current: [String: (bytesIn: UInt64, bytesOut: UInt64)])
        -> [String: (bytesIn: UInt64, bytesOut: UInt64)] {
        guard !current.isEmpty else { return [:] }

        defer { previous = current }

        var deltas: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        for (key, now) in current {
            // A process seen for the first time is baselined and contributes
            // nothing this round. Its figures are totals since it started,
            // which can be hours of traffic, and counting them as this minute's
            // usage would put a large phantom figure at the top of the list.
            // At worst this loses the first half minute of a new process, which
            // is well inside what the per-app figures already claim.
            guard let before = previous[key] else { continue }

            // A fall means the pid was reused by a different process. Re-baseline
            // rather than treat the new process's lifetime total as a delta.
            let deltaIn = now.bytesIn >= before.bytesIn ? now.bytesIn - before.bytesIn : 0
            let deltaOut = now.bytesOut >= before.bytesOut ? now.bytesOut - before.bytesOut : 0

            guard deltaIn > 0 || deltaOut > 0 else { continue }
            let name = Self.displayName(fromKey: key)
            let running = deltas[name] ?? (0, 0)
            deltas[name] = (running.bytesIn &+ deltaIn, running.bytesOut &+ deltaOut)
        }
        return deltas
    }

    /// Drop the previous totals, so the next call only baselines. For a
    /// pause in sampling: without it, the first call after the pause would
    /// book everything the processes carried while nobody was looking into
    /// that one minute.
    public mutating func forget() {
        previous = [:]
    }

    /// "Example Helper.512" becomes "Example Helper". Process names can contain
    /// dots, so only a trailing all digit segment is treated as the pid.
    static func displayName(fromKey key: String) -> String {
        guard let dot = key.lastIndex(of: "."), dot != key.startIndex else { return key }
        let tail = key[key.index(after: dot)...]
        guard !tail.isEmpty, tail.allSatisfy({ $0.isNumber }) else { return key }
        return String(key[key.startIndex..<dot])
    }
}
