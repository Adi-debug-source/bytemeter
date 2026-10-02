import Foundation
import BytemeterCore

/// `Bytemeter --dashboard` builds the dashboard from whatever is already in the
/// database and prints where it landed, without starting the menu bar app.
///
/// Useful for rebuilding the page without going through the menu, and it is how
/// the dashboard gets tested. It only reads the samples, except that opening
/// an older database brings its schema up to date first, as any open does.
/// The single instance lock is deliberately not taken, because this does not
/// sample anything.
enum DashboardCLI {

    /// An optional folder after the flag points at a different copy of the
    /// data, which is how the page gets tested against a known set of figures.
    static func run(folderArgument: String?) -> Int32 {
        let folder = folderArgument.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AppDelegate.supportFolder
        let path = folder.appendingPathComponent("bytemeter.db").path
        guard FileManager.default.fileExists(atPath: path) else {
            print("No database yet at \(path). Let Bytemeter run for a minute first.")
            return 1
        }
        do {
            let db = try Database(path: path)
            let settings = Settings(db: db, write: { work in work() })
            let cal = BytemeterCalendar(cycleStartDay: settings.cycleStartDay)
            let aggregator = Aggregator(db: db, cal: cal)
            let data = DashboardData(aggregator: aggregator, settings: settings, now: Date())
            let url = try DashboardGenerator.write(data: data, folder: folder)
            print(url.path)
            return 0
        } catch {
            print("Could not build the dashboard: \(error)")
            return 1
        }
    }
}
