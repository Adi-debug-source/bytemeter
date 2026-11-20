import Foundation

/// What to call an interface where a person reads it.
///
/// The kernel's names, en0 and en1 and the rest, are what the counters are
/// kept under, and they mean little to most people: which of them is the
/// Wi-Fi, and which the phone plugged in to share its connection? macOS has a
/// name for each port, such as Wi-Fi, Thunderbolt Ethernet or iPhone USB. The
/// app looks those up, since only it can, and hands them over as a plain
/// table, so the engine and the page stay free of anything macOS-only.
///
/// The names are today's: they describe the ports this Mac has now. An
/// interface that is no longer attached, such as an adapter since unplugged,
/// has no name to give, and is shown by its kernel name alone.
public enum InterfaceNames {

    /// "Wi-Fi (en0)" where the Mac names the port, "en0" where it does not.
    /// The kernel name always stays, because it is what the export and the
    /// events call the interface.
    public static func label(_ interface: String, names: [String: String]) -> String {
        guard let name = names[interface]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name != interface else { return interface }
        return "\(name) (\(interface))"
    }
}
