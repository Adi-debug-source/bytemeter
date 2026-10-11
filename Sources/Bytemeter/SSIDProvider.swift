import Foundation
import CoreWLAN
import BytemeterCore

/// Splitting traffic by Wi-Fi network keeps a home connection separate from a
/// phone hotspot or a cafe. macOS gives an app the network name only once the
/// user has allowed it Location Services: without that, `CWInterface.ssid()`
/// returns nil, which is why `networksetup` reports "You are not associated
/// with an AirPort network" while plainly connected.
///
/// So the name is read only when the box in Preferences is ticked and macOS
/// has said yes. Until then every minute gets the placeholder, and CoreWLAN is
/// not asked at all.
enum SSIDProvider {

    /// Called by the sampler on its own queue.
    static func currentSSID(enabled: Bool) -> String {
        currentSSID(enabled: enabled, permission: NetworkNameAccess.currentPermission) {
            CWWiFiClient.shared().interface()?.ssid()
        }
    }

    /// The same, with the permission and the read handed in, so the gate can
    /// be checked without CoreWLAN or Location Services.
    static func currentSSID(enabled: Bool, permission: NetworkNamePermission?, read: () -> String?) -> String {
        guard NetworkNames.shouldRead(boxTicked: enabled, permission: permission) else { return ssidPlaceholder }
        guard let name = read(), !name.isEmpty else { return NetworkNames.unknown }
        return name
    }
}
