import Foundation
import SystemConfiguration
import BytemeterCore

/// The names macOS gives this Mac's network ports, by kernel name: en0 is
/// "Wi-Fi", a phone sharing its connection over a cable is "iPhone USB". The
/// same names System Settings shows under Network. See `InterfaceNames` for
/// where they are used.
///
/// Read from the system's own configuration, on this Mac. Nothing is asked
/// of the network, and no permission is needed.
enum HardwarePorts {

    static func names() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var names: [String: String] = [:]
        for interface in interfaces {
            guard let kernelName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  InterfaceMonitor.isPhysical(kernelName),
                  let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else { continue }
            names[kernelName] = name
        }
        return names
    }
}
