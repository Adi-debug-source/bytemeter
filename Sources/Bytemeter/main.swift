import AppKit

// One flag, handled before anything else starts: rebuild the dashboard from the
// existing database and exit, without touching the menu bar.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--dashboard") {
    let next = CommandLine.arguments.index(after: flagIndex)
    let folder = next < CommandLine.arguments.endIndex ? CommandLine.arguments[next] : nil
    exit(DashboardCLI.run(folderArgument: folder))
}

// LSUIElement in Info.plist keeps Bytemeter out of the Dock; .accessory matches it
// here so the app behaves the same when run straight from the command line.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let delegate = AppDelegate()
application.delegate = delegate
application.run()
