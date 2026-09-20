// swift-tools-version:5.9
import PackageDescription

// Two targets on purpose. BytemeterCore is the shared engine and must stay free of
// AppKit and anything else macOS only, so an iOS sibling can use it untouched.
// Everything macOS specific (menu bar, nettop, dashboard, CoreWLAN) lives in Bytemeter.
//
// BytemeterSelfTest is a plain executable rather than a test target because
// XCTest cannot be resolved with the Command Line Tools alone, and this should
// build and test without full Xcode. Run it with: swift run -c release BytemeterSelfTest
let package = Package(
    name: "Bytemeter",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "BytemeterCore"),
        .executableTarget(name: "Bytemeter", dependencies: ["BytemeterCore"]),
        .executableTarget(name: "BytemeterSelfTest", dependencies: ["BytemeterCore"]),
    ]
)
