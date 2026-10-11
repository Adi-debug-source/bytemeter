// swift-tools-version:5.9
import PackageDescription

// Four targets on purpose. BytemeterCore is the engine and must stay free of
// AppKit and anything else macOS only, so an iOS sibling can use it untouched.
//
// BytemeterDashboard builds the dashboard page and its CSV export from the
// engine with Foundation alone, so the self-test can check them and another
// platform could show the same page.
//
// Bytemeter is the macOS app: the menu bar, nettop, CoreWLAN and Preferences.
//
// BytemeterSelfTest is a plain executable rather than a test target because
// XCTest is not part of the Command Line Tools, and this should build and test
// without full Xcode. Run it with: swift run -c release BytemeterSelfTest
let package = Package(
    name: "Bytemeter",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "BytemeterCore"),
        .target(name: "BytemeterDashboard", dependencies: ["BytemeterCore"]),
        .executableTarget(name: "Bytemeter", dependencies: ["BytemeterCore", "BytemeterDashboard"]),
        .executableTarget(name: "BytemeterSelfTest", dependencies: ["BytemeterCore", "BytemeterDashboard"]),
    ]
)
