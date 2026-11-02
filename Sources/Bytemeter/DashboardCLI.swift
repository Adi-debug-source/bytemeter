import Foundation
import BytemeterCore
import BytemeterDashboard

/// `Bytemeter --dashboard` builds the dashboard from whatever is already in the
/// database and prints where it landed, without starting the menu bar app.
///
/// Useful for rebuilding the page without going through the menu, and it is how
/// the dashboard gets tested. It only reads the samples, except that opening
/// an older database brings its schema up to date first, as any open does.
/// The single instance lock is deliberately not taken, because this does not
/// sample anything, and the app holds it for as long as it runs, so taking it
/// would refuse every run made while the app is up. If the app is upgrading
/// the file at that moment, the open waits for it (`Database.migrationWait`).
enum DashboardCLI {

    /// An optional folder points at a different copy of the data, which is how
    /// the page gets tested against a known set of figures. `asOf` draws the
    /// page as it would have looked at that moment, so screenshots can be
    /// reproduced at any hour; it is passed through as `now`, never faked.
    static func run(folderArgument: String?, asOf: Date?) -> Int32 {
        let folder = folderArgument.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? DataFolder.url
        let path = DataFolder.database(in: folder).path
        guard FileManager.default.fileExists(atPath: path) else {
            print("No database yet at \(path). Let Bytemeter run for a minute first.")
            return 1
        }
        do {
            let db = try Database(path: path)
            let settings = Settings(db: db, write: { work in work() })
            let cal = BytemeterCalendar(cycleStartDay: settings.cycleStartDay)
            let aggregator = Aggregator(db: db, cal: cal)
            let options = settings.dashboardOptions
            let data = DashboardData(aggregator: aggregator, options: options, now: asOf ?? Date())
            let url = try DashboardGenerator.write(data: data, folder: folder)
            print(url.path)
            return 0
        } catch {
            print("Could not build the dashboard: \(error)")
            return 1
        }
    }
}
