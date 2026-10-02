import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Which boot of the Mac this is, and when it began. Together they tell a
/// restart apart from everything else, and say where the traffic since a
/// restart belongs.
///
/// Both are kernel values that iOS has as well, so they live in the shared
/// engine. They are read here and passed into `Ledger.ingest`, which keeps the
/// ledger itself free of system calls and testable with any values.
public enum BootClock {

    /// Unix seconds at boot, or nil if it cannot be read.
    public static func bootTime() -> Int64? {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        let ok = mib.withUnsafeMutableBufferPointer { mibPtr -> Bool in
            sysctl(mibPtr.baseAddress, u_int(mibPtr.count), &value, &size, nil, 0) == 0
        }
        guard ok, size == MemoryLayout<timeval>.size, value.tv_sec > 0 else { return nil }
        return Int64(value.tv_sec)
    }

    /// `kern.bootsessionuuid`: a new value at every boot and at nothing else.
    /// Unlike the boot time, setting the clock does not move it, which is why
    /// it decides whether the Mac restarted. Nil if it cannot be read.
    public static func bootSession() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        // A comma would break the stored baseline's format; a real id never has one.
        return value.isEmpty || value.contains(",") ? nil : value
    }
}
