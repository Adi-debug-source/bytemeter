import Foundation
import CoreGraphics

/// Was anyone at the keyboard when this bucket was written?
///
/// The point is to catch a backup or an updater quietly eating a shared line
/// while nobody is at the machine. Five minutes without any input counts
/// as idle.
enum IdleMonitor {
    static let thresholdSeconds: Double = 5 * 60

    /// kCGAnyInputEventType, which is UInt32.max, covers keyboard, mouse and
    /// trackpad in one call rather than asking about each event type.
    private static let anyInputEvent = CGEventType(rawValue: UInt32.max)

    static func secondsSinceLastInput() -> Double {
        guard let type = anyInputEvent else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type)
    }

    static func isIdle() -> Bool { secondsSinceLastInput() >= thresholdSeconds }
}
