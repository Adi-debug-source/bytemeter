import Foundation

/// What the sampler knows about sleep, kept apart from its timers and
/// notifications so the order of events can be tested.
///
/// Not thread safe, on purpose: one serial queue owns it, the same queue
/// that writes the database, so a sleep, a wake and a timer reading can
/// never interleave. The sampler hands every notification to that queue
/// rather than touching this from the main thread.
public final class SleepGate {
    /// While true, readings are skipped. Nothing about the counters is
    /// trustworthy between the sleep notice and the wake.
    public private(set) var asleep = false

    /// Why there may be a gap before the next reading. Cleared only by a
    /// reading that was actually written, so a failed write passes the
    /// label on to the reading that finally covers the gap.
    public private(set) var pendingReason: GapReason = .relaunch

    public init() {}

    /// The reason to give a reading taken now, or nil while asleep.
    public var reasonForReading: GapReason? { asleep ? nil : pendingReason }

    /// A reading was written: the gap before it is accounted for.
    public func readingWritten() { pendingReason = .normal }

    /// The Mac is about to sleep. Takes the last reading first and only then
    /// shuts the gate. The other order shuts `lastReading` out too, so the
    /// counters would last have been saved up to 5 seconds before sleep.
    public func enterSleep(lastReading: () -> Void) {
        lastReading()
        asleep = true
        pendingReason = .sleep
    }

    /// The Mac has woken. Opens the gate and labels the gap before
    /// `firstReading` as sleep, even if the sleep notice never came.
    public func wake(firstReading: () -> Void) {
        asleep = false
        pendingReason = .sleep
        firstReading()
    }
}
