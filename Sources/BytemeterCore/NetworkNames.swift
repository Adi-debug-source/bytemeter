import Foundation

// MARK: - Wi-Fi network names

/// What macOS says about Bytemeter using Location Services, which it needs
/// before it will give any app the Wi-Fi network name. The app maps Core
/// Location's own status onto this, so the engine never imports Core Location.
public enum NetworkNamePermission: Equatable {
    case notAsked
    case allowed
    case denied
    case restricted
}

/// The rules for recording network names, kept apart from Core Location so
/// every state can be checked without a permission prompt.
///
/// The box in Preferences is what the user wants; Location Services is what
/// macOS allows. A name is read only when both say yes. macOS is asked only
/// when the user ticks the box or chooses Ask macOS, never at launch, and
/// never while the box is off.
public enum NetworkNames {

    /// Recorded for a minute when the name was not read at all: the box was
    /// off, or macOS had not allowed it yet. The database keeps the plain
    /// placeholder; this is how the dashboard and the export show it.
    public static let notRecorded = "Not recorded"
    /// Recorded when the name was asked for and macOS gave none, for example
    /// with Wi-Fi switched off.
    public static let unknown = "Unknown network"

    public static func displayName(_ stored: String) -> String {
        stored == ssidPlaceholder ? notRecorded : stored
    }

    public enum Status: Equatable {
        /// The box is off.
        case off
        /// The box is on and macOS allows it: names are being recorded.
        case recording
        /// The box was just ticked and macOS is asking; no answer yet.
        case asking
        /// The box is on, but this copy of Bytemeter has not been asked, as
        /// after an update. Nothing asks at launch, so it waits for the user.
        case notAskedYet
        /// macOS does not allow it, so the box has been switched off.
        case refused
        /// Location Services is restricted on this Mac, so the box has been
        /// switched off and cannot be turned on from here.
        case restricted
        /// The box is on, and Location Services was not consulted: the
        /// dashboard built from the command line, which never touches it.
        case unchecked
    }

    /// `permission` is nil when Location Services has not been consulted.
    public static func status(boxTicked: Bool, permission: NetworkNamePermission?, asking: Bool) -> Status {
        switch (boxTicked, permission) {
        case (_, .denied?): return .refused
        case (_, .restricted?): return .restricted
        case (false, _): return .off
        case (true, nil): return .unchecked
        case (true, .allowed?): return .recording
        case (true, .notAsked?): return asking ? .asking : .notAskedYet
        }
    }

    /// The one gate in front of reading the name.
    public static func shouldRead(boxTicked: Bool, permission: NetworkNamePermission?) -> Bool {
        boxTicked && permission == .allowed
    }

    /// Whether ticking the box should ask macOS. Only when it has never been
    /// asked: once it has answered, macOS ignores the request anyway.
    public static func asksOnTick(_ permission: NetworkNamePermission) -> Bool {
        permission == .notAsked
    }

    /// False when the box must be switched back off.
    public static func keepsBoxTicked(_ permission: NetworkNamePermission) -> Bool {
        permission != .denied && permission != .restricted
    }

    /// The button Preferences offers beside the note, if any.
    public enum Action: Equatable {
        case ask
        case openSettings
    }

    public static func action(_ status: Status) -> Action? {
        switch status {
        case .asking, .notAskedYet: return .ask
        case .refused: return .openSettings
        case .off, .recording, .restricted, .unchecked: return nil
        }
    }

    /// Under the box in Preferences, always shown.
    public static let preferencesCaption = "Keeps a home connection separate from a hotspot or a cafe. macOS gives an app "
        + "the Wi-Fi network name only with Location Services permission, so ticking this asks for it. Bytemeter "
        + "reads the network name and nothing else about where the Mac is. While this is off, it does not use "
        + "Location Services at all."

    /// Where permission is granted, in the words of System Settings.
    public static let settingsPath = "System Settings, then Privacy & Security, then Location Services"

    /// The line under the caption saying where things stand, if anything needs saying.
    public static func preferencesNote(_ status: Status) -> String? {
        switch status {
        case .off, .unchecked:
            return nil
        case .recording:
            return "Location Services allows it, so network names are being recorded."
        case .asking:
            return "macOS is asking whether Bytemeter may use Location Services. Network names are recorded once "
                + "you allow it. If no question appeared, choose Ask macOS."
        case .notAskedYet:
            return "Network names are not being recorded yet. macOS has not been asked on this copy of Bytemeter, "
                + "which can happen after an update. Choose Ask macOS to ask now."
        case .refused:
            return "Switched off, because macOS does not allow Bytemeter to use Location Services. To allow it, "
                + "open \(settingsPath), make sure Location Services is on, and switch on Bytemeter in the list. "
                + "Then tick this box again."
        case .restricted:
            return "Switched off, because Location Services is restricted on this Mac, for example by a "
                + "management profile, so it cannot be allowed from here."
        }
    }

    /// The "Per network" note on the dashboard, describing what was actually recorded.
    public static func dashboardNote(_ status: Status) -> String {
        let legend = "\(notRecorded) covers minutes when the name was not read: before recording was switched on, "
            + "or while macOS did not allow it. \(unknown) means macOS gave no name, for example while Wi-Fi was off."
        switch status {
        case .off:
            return "Network name recording is off, so traffic is not split by network. Switching it on in "
                + "Preferences asks macOS for Location Services, which macOS requires before it gives any app a "
                + "Wi-Fi network name. While it is off, Bytemeter does not use Location Services at all."
        case .recording, .unchecked:
            return "Each minute is recorded against the Wi-Fi network the Mac was on. " + legend
        case .asking, .notAskedYet:
            return "Network name recording is switched on, but macOS has not yet allowed Bytemeter to use "
                + "Location Services, so new minutes are \(notRecorded.lowercased()). Preferences can ask again. "
                + legend
        case .refused:
            return "Network name recording was switched off because macOS does not allow Bytemeter to use "
                + "Location Services. Preferences says where to allow it."
        case .restricted:
            return "Network name recording was switched off because Location Services is restricted on this Mac."
        }
    }
}
