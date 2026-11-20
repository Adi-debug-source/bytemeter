// Takes the README's picture of the menu, from the real app running read-only
// on a demo database:
//
//   swift Scripts/menu_shots.swift <demo folder> <as of> <output.png>
//
// It starts `Bytemeter --demo <folder> --as-of <time> --open-menu`, waits for
// the menu to open, has macOS's own screencapture take the menu's window, and
// trims the picture to the menu's edge, so there is no shadow. Nothing is
// clicked, the demo database is only read, and a running Bytemeter is left
// alone, as --demo always leaves it.
//
// Run it from the top of the repository. It needs a build (swift build -c release), a demo database already brought
// up to date by one run of --dashboard on its folder, and macOS's permission
// for the terminal it runs in to record the screen, which screencapture asks
// for. The picture is as sharp as the screen, so take it on a Retina screen,
// with the Mac in dark mode, as the dashboard is dark too.
//
// A capture is tagged with the display's colour profile, so convert it to
// sRGB and strip it afterwards, as MAINTENANCE.md says under Screenshots.

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The demo while it runs, and the whole capture before it is trimmed, so a
/// failure at any point ends the one and removes the other. `exit` skips
/// every `defer`, so `fail` and the last line see to both.
var runningDemo: Process?
var scratch: URL?

func tidyUp() {
    runningDemo?.terminate()
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
}

func fail(_ message: String) -> Never {
    tidyUp()
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

@discardableResult
func run(_ tool: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { fail("Could not run \(tool): \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("Usage: swift Scripts/menu_shots.swift <demo folder> <as of, such as 2026-09-29T21:30> <output.png>")
}
let folder = arguments[1]
let asOf = arguments[2]
let output = URL(fileURLWithPath: arguments[3])
let binary = FileManager.default.currentDirectoryPath + "/.build/release/Bytemeter"
guard FileManager.default.isExecutableFile(atPath: binary) else { fail("No build at \(binary). Run: swift build -c release") }
guard FileManager.default.fileExists(atPath: folder + "/bytemeter.db") else { fail("No demo database in \(folder).") }

/// A window of the demo's: where it is, and whether it is the one drawn on screen.
struct Window {
    let id: Int
    let bounds: CGRect
    let onScreen: Bool
}

func windows(of pid: Int32) -> [Window] {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { window in
        guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              let id = (window[kCGWindowNumber as String] as? NSNumber)?.intValue,
              let box = window[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return Window(id: id,
                      bounds: CGRect(x: box["X"] ?? 0, y: box["Y"] ?? 0, width: box["Width"] ?? 0, height: box["Height"] ?? 0),
                      onScreen: (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
    }
}

let demo = Process()
demo.executableURL = URL(fileURLWithPath: binary)
demo.arguments = ["--demo", folder, "--as-of", asOf, "--open-menu"]
// Its own words go to the terminal, so a refusal says why in its own terms.
do { try demo.run() } catch { fail("Could not start the demo: \(error)") }
runningDemo = demo

// An open menu is two windows, one inside the other: the menu itself, and
// around it the one macOS draws on screen, which carries the shadow as well.
// The menu opens a second after launch; wait for both, then let it draw.
var drawn: Window?
var menu: Window?
for _ in 0..<40 {
    usleep(250_000)
    guard demo.isRunning else {
        fail("The demo did not stay running; it says why above. A new demo database is brought up to date by "
             + "building the dashboard from its folder once: .build/release/Bytemeter --dashboard \(folder) --as-of \(asOf)")
    }
    let found = windows(of: demo.processIdentifier)
    drawn = found.filter(\.onScreen).max { $0.bounds.height < $1.bounds.height }
    menu = drawn.flatMap { outer in
        found.filter { !$0.onScreen && outer.bounds.contains($0.bounds) && $0.bounds.minX > outer.bounds.minX }
            .max { $0.bounds.height < $1.bounds.height }
    }
    if menu != nil { break }
}
guard let drawn, let menu else { fail("The demo's menu did not open.") }
usleep(600_000)

let whole = FileManager.default.temporaryDirectory.appendingPathComponent("bytemeter_menu_\(UUID().uuidString).png")
scratch = whole
run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(drawn.id), whole.path])
guard let source = CGImageSourceCreateWithURL(whole as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("screencapture wrote nothing. Allow this terminal to record the screen in System Settings, Privacy & Security.")
}

// The menu's own box inside the picture, in the picture's pixels.
let scale = CGFloat(image.width) / drawn.bounds.width
let box = CGRect(x: (menu.bounds.minX - drawn.bounds.minX) * scale, y: (menu.bounds.minY - drawn.bounds.minY) * scale,
                 width: menu.bounds.width * scale, height: menu.bounds.height * scale).integral
guard let trimmed = image.cropping(to: box),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("Could not trim the picture to the menu.")
}
CGImageDestinationAddImage(destination, trimmed, nil)
guard CGImageDestinationFinalize(destination) else { fail("Could not write \(output.path).") }
tidyUp()
print("Wrote \(output.path), \(trimmed.width) by \(trimmed.height) pixels.")
