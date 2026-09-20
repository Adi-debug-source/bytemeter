import Foundation
import BytemeterCore

/// Per process byte counts, from `nettop`.
///
/// A note on honesty, which the UI repeats: this is a good guide, not an exact
/// split. `nettop` reports totals since each process started, so a process that
/// exits between two samples takes its unreported tail with it. The interface
/// counters are the source of truth and the two will not reconcile exactly.
final class NettopSampler {

    /// Cumulative totals from the previous run, keyed by "name.pid".
    private var previous: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]

    /// One shot invocations rather than a long lived stream.
    ///
    /// The brief preferred a streaming subprocess, and that was tried first.
    /// `nettop` without -L is a curses program: with no terminal it exits with
    /// "Error opening terminal: unknown", and given a TERM it emits cursor
    /// positioning escape sequences rather than rows. Parsing that would be
    /// guesswork, so the documented fallback is used instead. Verified 20
    /// September 2026.
    private static let arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]

    /// Returns bytes used per process since the previous call, keyed by process
    /// name with the pid stripped.
    func sampleDeltas() -> [String: (bytesIn: UInt64, bytesOut: UInt64)] {
        guard let output = runNettop() else { return [:] }

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
            let name = displayName(from: key)
            let running = deltas[name] ?? (0, 0)
            deltas[name] = (running.bytesIn &+ deltaIn, running.bytesOut &+ deltaOut)
        }
        return deltas
    }

    /// "Example Helper.512" becomes "Example Helper". Process names can contain
    /// dots, so only a trailing all digit segment is treated as the pid.
    private func displayName(from key: String) -> String {
        guard let dot = key.lastIndex(of: "."), dot != key.startIndex else { return key }
        let tail = key[key.index(after: dot)...]
        guard !tail.isEmpty, tail.allSatisfy({ $0.isNumber }) else { return key }
        return String(key[key.startIndex..<dot])
    }

    private func runNettop() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = Self.arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch {
            FileHandle.standardError.write(Data("Bytemeter: could not run nettop: \(error)\n".utf8))
            return nil
        }

        // A watchdog, so a wedged nettop can never stall sampling for good.
        // If it fires, the output is half a list, and a half list is worse than
        // none: the processes missing from it would look brand new next time.
        // So a terminated run is discarded rather than parsed.
        let timedOut = Atomic(false)
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOut.set(true)
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard !timedOut.get(), process.terminationStatus == 0 else {
            FileHandle.standardError.write(Data("Bytemeter: nettop sample discarded, incomplete output.\n".utf8))
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}


/// A tiny lock around one flag, shared between the watchdog and the reader.
final class Atomic {
    private var value: Bool
    private let lock = NSLock()
    init(_ value: Bool) { self.value = value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
