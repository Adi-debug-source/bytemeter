import AppKit
import BytemeterCore

/// `Bytemeter --demo <folder> [--as-of <time>]`.
///
/// What it is for: the README's picture of the menu has to be the real app's
/// real menu, not a mock-up, and it must not show anyone's real figures or app
/// names. This runs the real status item and the real menu, built by exactly
/// the code the app always uses, against a demo database such as the one
/// `Scripts/make_demo_db.py` writes, as of the moment given.
///
/// Strictly read only:
/// 1. The database is opened immutable, so nothing is written to it or beside it.
/// 2. There is no sampler, no nettop and no maintenance timer.
/// 3. Settings changed from its menu, such as the mode or live speed, live in
///    memory and are never saved.
/// 4. It never takes the single instance lock, so a copy of Bytemeter that is
///    counting for real carries on and never notices; and it refuses to open
///    the real data folder at all.
/// 5. Open dashboard and Preferences do nothing here, because both would write.
/// 6. Its menu bar item has its own autosave name, so where macOS remembers the
///    real item sitting is left alone. Run it from the build folder rather than
///    the installed app, so it does not share the app's preferences either.
/// Quit ends it, as it ends the app.
final class DemoDelegate: NSObject, NSApplicationDelegate {

    private let db: Database
    private let asOf: Date?
    private var settings: Settings?
    private var statusController: StatusItemController?

    private init(db: Database, asOf: Date?) {
        self.db = db
        self.asOf = asOf
    }

    /// Opens the demo database, or says on standard error why it will not.
    static func make(folder: String, asOf: Date?) -> DemoDelegate? {
        let url = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let real = AppDelegate.supportFolder.standardizedFileURL.resolvingSymlinksInPath()
        guard url.path != real.path else {
            complain("--demo will not open Bytemeter's own data folder. It is for a demo database, such as "
                     + "one made by Scripts/make_demo_db.py.")
            return nil
        }
        do {
            let db = try Database(readOnlyPath: url.appendingPathComponent("bytemeter.db").path)
            return DemoDelegate(db: db, asOf: asOf)
        } catch {
            complain("--demo could not open the demo database: \(error).")
            return nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let database = db
        // Reads the demo database's own settings, and saves nothing back.
        let settings = Settings(db: database, write: { _ in })
        self.settings = settings
        let asOf = self.asOf
        let controller = StatusItemController(settings: settings, clock: { asOf ?? Date() },
                                              autosaveName: "BytemeterDemo") { body in
            body(Aggregator(db: database, cal: BytemeterCalendar(cycleStartDay: settings.cycleStartDay)))
        }
        controller.onOpenDashboard = { Self.complain("Open dashboard does nothing in demo mode.") }
        controller.onOpenPreferences = { Self.complain("Preferences do nothing in demo mode.") }
        statusController = controller

        let moment = asOf.map { "as of " + BytemeterCalendar().timestampLabel($0) } ?? "as of now"
        Self.complain("Bytemeter demo: showing \(database.path), \(moment). Read only. "
                      + "Choose Quit from its menu to end it.")
    }

    private static func complain(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
