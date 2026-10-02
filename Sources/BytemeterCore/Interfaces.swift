import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One interface's cumulative byte counters, as read from the kernel, and
/// which counter they were read from.
public struct InterfaceReading: Equatable {
    public let name: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    /// Each reading carries its own source, because the fallback happens one
    /// interface at a time: en0 can come from the MIB while en1 comes from
    /// getifaddrs in the same snapshot.
    public let source: CounterSource

    public init(name: String, bytesIn: UInt64, bytesOut: UInt64, source: CounterSource = .mib64) {
        self.name = name
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.source = source
    }
}

/// Where a reading came from. This is not trivia: the 32 bit source wraps at
/// 4,294,967,296 bytes and needs wrap handling, the 64 bit one does not, and
/// a value from one can never be compared with a value from the other.
public enum CounterSource: String {
    case mib64      // sysctl net.link.generic.ifdata.<index>.general, a real if_data64
    case ifdata32   // getifaddrs ifa_data, a 32 bit if_data, wraps every 4.29 GB

    /// Words for an event, so the log says which counter was meant.
    public var phrase: String {
        switch self {
        case .mib64: return "the 64 bit interface MIB"
        case .ifdata32: return "the 32 bit getifaddrs counter"
        }
    }
}

public struct InterfaceSnapshot {
    public let readings: [InterfaceReading]

    public init(readings: [InterfaceReading]) {
        self.readings = readings
    }

    /// One word for the whole snapshot, for the dashboard and the seed event:
    /// 32 bit if any interface had to fall back. Only a summary. The ledger
    /// goes by each reading's own source.
    public var source: CounterSource {
        readings.contains { $0.source == .ifdata32 } ? .ifdata32 : .mib64
    }
}

public enum InterfaceMonitor {

    // Constants copied from the system headers rather than imported, because the
    // Swift importer does not reliably surface these particular #defines.
    // PF_LINK is AF_LINK (sys/socket.h). The rest are from net/if_mib.h.
    private static let pfLink: Int32 = 18
    private static let netlinkGeneric: Int32 = 0
    private static let ifmibIfdata: Int32 = 2
    private static let ifdataGeneral: Int32 = 1

    /// Count only physical interfaces: en0, en1 and friends.
    ///
    /// The exclusions matter more than the inclusions. A VPN's `utun` interface
    /// carries the very same bytes as the Wi-Fi interface underneath it, so
    /// counting both would double every figure the moment a VPN is switched on.
    /// The same argument applies to `bridge*` (it bridges members that are
    /// already counted). `awdl0` and `llw0` are AirDrop and low latency
    /// peer to peer links, `ap1` is the internal access point interface, `lo0`
    /// is loopback and never leaves the machine, `gif*` and `stf*` are tunnels.
    /// None of them are traffic over your own line.
    public static func isPhysical(_ name: String) -> Bool {
        guard name.hasPrefix("en") else { return false }
        let suffix = name.dropFirst(2)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber }
    }

    /// Every interface name the kernel currently reports at the link layer.
    public static func allLinkInterfaceNames() -> [String] {
        var names: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return names }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            if let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: entry.pointee.ifa_name)
                if !names.contains(name) { names.append(name) }
            }
            cursor = entry.pointee.ifa_next
        }
        return names
    }

    /// The 64 bit counter for one interface, via the interface MIB.
    ///
    /// This is deliberately not getifaddrs. On macOS getifaddrs returns a
    /// `struct if_data`, whose ifi_ibytes is a u_int32_t, so once an interface
    /// passes 4.29 GB since boot, which a busy day easily does, that field has
    /// wrapped and reads about 4.29 GB low. The route socket NET_RT_IFLIST2 path returns the same
    /// truncated value. `net.link.generic.ifdata.<index>.general` fills a
    /// `struct ifmibdata`, whose ifmd_data really is an `if_data64`, and its
    /// value matches netstat -ib exactly. Verified 20 September 2026.
    private static func mibReading(index: UInt32) -> (UInt64, UInt64)? {
        var mib: [Int32] = [CTL_NET, pfLink, netlinkGeneric, ifmibIfdata, Int32(bitPattern: index), ifdataGeneral]
        var data = ifmibdata()
        var size = MemoryLayout<ifmibdata>.size
        let ok = withUnsafeMutablePointer(to: &data) { dataPtr -> Bool in
            mib.withUnsafeMutableBufferPointer { mibPtr -> Bool in
                sysctl(mibPtr.baseAddress, u_int(mibPtr.count), dataPtr, &size, nil, 0) == 0
            }
        }
        guard ok else { return nil }
        return (data.ifmd_data.ifi_ibytes, data.ifmd_data.ifi_obytes)
    }

    /// The 32 bit counters from getifaddrs, used only if the MIB read fails.
    private static func ifdataReadings() -> [String: (UInt64, UInt64)] {
        var out: [String: (UInt64, UInt64)] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            if let addr = entry.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_LINK),
               let raw = entry.pointee.ifa_data {
                let name = String(cString: entry.pointee.ifa_name)
                let stats = raw.assumingMemoryBound(to: if_data.self).pointee
                out[name] = (UInt64(stats.ifi_ibytes), UInt64(stats.ifi_obytes))
            }
            cursor = entry.pointee.ifa_next
        }
        return out
    }

    /// Read every physical interface. Prefers the 64 bit MIB and only falls back
    /// to the 32 bit counters if the MIB is unavailable.
    public static func read() -> InterfaceSnapshot {
        let names = allLinkInterfaceNames().filter(isPhysical)
        return assemble(names: names,
                        mib: { name in
                            let index = name.withCString { if_nametoindex($0) }
                            return index == 0 ? nil : mibReading(index: index)
                        },
                        fallback: ifdataReadings)
    }

    /// The choice of counter, one interface at a time, apart from the system
    /// calls so it can be tested. `mib` answers for one interface or fails;
    /// `fallback` is asked at most once, and only if some interface needed it.
    /// Every reading is labelled with the counter it really came from.
    public static func assemble(names: [String],
                                mib: (String) -> (UInt64, UInt64)?,
                                fallback: () -> [String: (UInt64, UInt64)]) -> InterfaceSnapshot {
        var readings: [InterfaceReading] = []
        var fallbackValues: [String: (UInt64, UInt64)]?

        for name in names.sorted() {
            if let (bin, bout) = mib(name) {
                readings.append(InterfaceReading(name: name, bytesIn: bin, bytesOut: bout, source: .mib64))
            } else {
                if fallbackValues == nil { fallbackValues = fallback() }
                if let (bin, bout) = fallbackValues?[name] {
                    readings.append(InterfaceReading(name: name, bytesIn: bin, bytesOut: bout, source: .ifdata32))
                }
            }
        }
        return InterfaceSnapshot(readings: readings)
    }
}
