import Foundation
import CoreWLAN
import BytemeterCore

/// Splitting traffic by Wi-Fi network keeps a home connection separate from a
/// phone hotspot or a cafe. Reading the network name needs a Location Services
/// grant on this version of macOS, which is why `networksetup` reports "You are
/// not associated with an AirPort network" while plainly connected.
///
/// So this is off by default and, while it is off, CoreWLAN is never touched at
/// all and no permission prompt can appear.
enum SSIDProvider {

    static func currentSSID(enabled: Bool) -> String {
        guard enabled else { return ssidPlaceholder }
        guard let name = CWWiFiClient.shared().interface()?.ssid(), !name.isEmpty else {
            return "Unknown network"
        }
        return name
    }
}
