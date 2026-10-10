import Foundation
import BytemeterCore

/// Per process byte counts, from `nettop`.
///
/// A note on honesty, which the UI repeats: this is a good guide, not an exact
/// split. `nettop` reports totals since each process started, so a process that
/// exits between two samples takes its unreported tail with it. The interface
/// counters are the source of truth and the two will not reconcile exactly.
final class NettopSampler {

    /// The previous run's totals and the arithmetic on them. Touched only
    /// on the queue that runs this sampler.
    private var tally = ProcessTally()

    /// One shot invocations rather than a long lived stream.
    ///
    /// A streaming subprocess would have been the better shape, and was tried first.
    /// `nettop` without -L is a curses program: with no terminal it exits with
    /// "Error opening terminal: unknown", and given a TERM it emits cursor
    /// positioning escape sequences rather than rows. Parsing that would be
    /// guesswork, so it is run once per sample instead. Verified 20
    /// September 2026.
    ///
    /// `-t external` leaves out loopback. Loopback traffic never leaves the
    /// Mac, so without it a local development server, a database or a VPN
    /// client's local proxy could top Top talkers with bytes that no counted
    /// interface carried. `external` is every interface but loopback (man
    /// nettop). A run also returns in hundredths of a second rather than
    /// about five. Verified 10 October 2026.
    private static let arguments = ["-P", "-L", "1", "-t", "external", "-x", "-J", "bytes_in,bytes_out"]

    /// Returns bytes used per process since the previous call, keyed by process
    /// name with the pid stripped. A run that fails leaves the previous
    /// totals as they were.
    func sampleDeltas() -> [String: (bytesIn: UInt64, bytesOut: UInt64)] {
        guard let output = runNettop() else { return [:] }
        return tally.deltas(ProcessTally.parse(output))
    }

    /// Drop the previous totals, so the next sample only baselines. Called
    /// while per-app sampling is off; see `ProcessTally.forget`.
    func forget() {
        tally.forget()
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
