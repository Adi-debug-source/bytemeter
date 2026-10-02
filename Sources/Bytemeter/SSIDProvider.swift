import Foundation
import CoreLocation
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

// MARK: - Location Services

/// What `NetworkNameAccess` needs from Location Services. The real one wraps
/// `CLLocationManager`; a stand-in can take its place to drive every state
/// without a prompt.
protocol LocationAuthoriser: AnyObject {
    var permission: NetworkNamePermission { get }
    /// Called on the main thread whenever macOS reports a status, including
    /// once shortly after the authoriser is made.
    var onChange: ((NetworkNamePermission) -> Void)? { get set }
    /// Asks macOS. Shows the question only if it has never been answered.
    func request()
}

/// Core Location's own manager. Made on the main thread, so its callbacks
/// arrive there too. Making one does not ask anything; only `request` does.
final class CoreLocationAuthoriser: NSObject, LocationAuthoriser, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    var onChange: ((NetworkNamePermission) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var permission: NetworkNamePermission { Self.permission(manager.authorizationStatus) }

    /// "When in use" is the only kind of request a Mac app can make that suits
    /// this: nothing here runs in the background on location's account. It
    /// needs NSLocationWhenInUseUsageDescription in Info.plist, or macOS
    /// silently ignores it.
    func request() { manager.requestWhenInUseAuthorization() }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onChange?(permission)
    }

    /// On macOS a yes is reported as `authorizedAlways`; `authorized` is the
    /// same value. `authorizedWhenInUse` is marked unavailable on macOS, so
    /// it can only be matched by its raw value, 4, should a later macOS send it.
    /// Any other value nobody knows yet is taken as not allowed, so the box
    /// visibly refuses to stay on rather than quietly reading nothing.
    static func permission(_ status: CLAuthorizationStatus) -> NetworkNamePermission {
        switch status {
        case .notDetermined: return .notAsked
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedAlways: return .allowed
        @unknown default: return status.rawValue == 4 ? .allowed : .denied
        }
    }
}

/// Keeps the network name box and Location Services in step.
///
/// Rules, all decided in `NetworkNames` in the engine:
/// 1. While the box is off, no authoriser exists, so Location Services is not
///    touched. Unticking lets go at once; a refusal lets go a moment later.
/// 2. macOS is asked only from `switchOn` and `askAgain`, both a click in
///    Preferences. `start`, at launch, only looks.
/// 3. If macOS refuses, or Location Services is restricted, the box is
///    switched back off and Preferences says why.
/// 4. The sampler reads the name only when the box is on and macOS has said yes.
final class NetworkNameAccess {

    private let settings: Settings
    private let makeAuthoriser: () -> LocationAuthoriser
    private var authoriser: LocationAuthoriser?
    private(set) var asking = false

    /// Called on the main thread after anything changes, for Preferences.
    var onUpdate: (() -> Void)?

    init(settings: Settings, makeAuthoriser: @escaping () -> LocationAuthoriser = { CoreLocationAuthoriser() }) {
        self.settings = settings
        self.makeAuthoriser = makeAuthoriser
    }

    // The sampler reads this from its own queue, so it lives behind a lock.
    private static let lock = NSLock()
    private static var _currentPermission: NetworkNamePermission?
    static var currentPermission: NetworkNamePermission? {
        get { lock.lock(); defer { lock.unlock() }; return _currentPermission }
        set { lock.lock(); _currentPermission = newValue; lock.unlock() }
    }

    var permission: NetworkNamePermission? { Self.currentPermission }

    var status: NetworkNames.Status {
        NetworkNames.status(boxTicked: settings.ssidCapture, permission: permission, asking: asking)
    }

    /// At launch. Looks only if the box is already on, and never asks: after
    /// an update macOS may not know this copy, and that waits for a click.
    func start() {
        guard settings.ssidCapture else { return }
        settle(connect().permission)
    }

    /// The box was ticked.
    func switchOn() {
        settings.ssidCapture = true
        let current = connect()
        let permission = current.permission
        if NetworkNames.asksOnTick(permission) {
            asking = true
            current.request()
        }
        settle(permission)
    }

    /// The Ask macOS button, for a box that is on but has no answer yet.
    func askAgain() {
        guard settings.ssidCapture, let current = authoriser,
              NetworkNames.action(status) == .ask else { return }
        asking = true
        current.request()
        settle(current.permission)
    }

    /// The box was unticked. Lets go of Location Services altogether.
    func switchOff() {
        settings.ssidCapture = false
        asking = false
        authoriser = nil
        Self.currentPermission = nil
        onUpdate?()
    }

    private func connect() -> LocationAuthoriser {
        if let existing = authoriser { return existing }
        let made = makeAuthoriser()
        made.onChange = { [weak self] permission in self?.settle(permission) }
        authoriser = made
        return made
    }

    /// Takes in what macOS said, whether just now or at launch.
    private func settle(_ permission: NetworkNamePermission) {
        if permission != .notAsked { asking = false }
        let switchingOff = settings.ssidCapture && !NetworkNames.keepsBoxTicked(permission)
        if switchingOff { settings.ssidCapture = false }
        // Kept after a refusal, so Preferences can still say why. Ticking the
        // box again reads the live answer from a new manager.
        Self.currentPermission = permission
        if switchingOff {
            // Lets go of Location Services, as unticking the box does. Not from
            // inside this call, which may be the manager's own callback, so on
            // the next pass of the main loop, and only if the box is still off.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.settings.ssidCapture else { return }
                self.authoriser = nil
            }
        }
        onUpdate?()
    }
}
