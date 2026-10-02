import Foundation

/// Every key used in the `state` table, in one place so nothing is typed twice.
public enum StateKey {
    /// Last raw counter per interface, as "bytesIn,bytesOut,unixSeconds", with
    /// ",bootSession" after it once the boot session id is known.
    /// Persisting this after every sample is what lets the app recover the
    /// traffic that happened while it was not running.
    public static func rawCounter(_ iface: String) -> String { "raw:\(iface)" }

    public static let statusMode = "status_mode"            // today, week, month or all_time
    public static let liveSpeed = "live_speed"              // the toggle the user flips
    public static let ssidCapture = "ssid_capture"          // off by default
    public static let perAppSampling = "per_app_sampling"   // on by default
    public static let seenMenuHint = "seen_menu_hint"
    public static let seedRecorded = "seed_recorded"
    public static let lastMaintenance = "last_maintenance"  // unix seconds
    public static let counterSource = "counter_source"

    // Cap machinery. Built and wired, switched off. It can be turned on later
    // without a rebuild.
    public static let capEnabled = "cap_enabled"
    public static let capBytes = "cap_bytes"
    public static let cycleStartDay = "cycle_start_day"     // 1 means calendar months
}

/// The placeholder written into the `ssid` column when SSID capture is off.
/// A constant rather than NULL keeps the primary key simple and the queries
/// identical whether capture is on or off.
public let ssidPlaceholder = "-"
