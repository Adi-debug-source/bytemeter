import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// When the kernel booted, which is what tells a restart apart from an
/// interface reset when a counter goes backwards.
///
/// `kern.boottime` is exact and available on iOS as well, so it lives in the
/// shared engine. It is read here and passed into `Ledger.ingest`, which keeps
/// the ledger itself free of system calls and testable with any boot time.
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
}
