import AppKit

// The command line is settled before anything else starts. The dashboard
// flag builds the page and exits without touching the menu bar; the demo flag
// runs the real menu bar item against a demo database; with neither, this is
// the menu bar app.
let options: LaunchOptions
switch LaunchOptions.parse(CommandLine.arguments) {
case .success(let parsed):
    options = parsed
case .failure(let error):
    FileHandle.standardError.write(Data("Bytemeter: \(error.message)\n\n\(LaunchOptions.usage)\n".utf8))
    exit(2)
}

/// Runs the menu bar side with this delegate until Quit. NSApplication holds
/// its delegate weakly, so this keeps it alive for the life of the run loop.
func runMenuBar(with delegate: NSApplicationDelegate) -> Never {
    // LSUIElement in Info.plist keeps Bytemeter out of the Dock; .accessory
    // matches it here so the app behaves the same when run from the command line.
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        application.delegate = delegate
        application.run()
    }
    exit(0)
}

switch options.mode {
case .help:
    print(LaunchOptions.usage)
    exit(0)
case .dashboard(let folder):
    exit(DashboardCLI.run(folderArgument: folder, asOf: options.asOf))
case .demo(let folder):
    guard let demo = DemoDelegate.make(folder: folder, asOf: options.asOf) else { exit(1) }
    runMenuBar(with: demo)
case .app:
    runMenuBar(with: AppDelegate())
}
