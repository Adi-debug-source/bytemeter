import Foundation

/// Where Bytemeter keeps its data: `~/Library/Application Support/Bytemeter`,
/// holding the database and the single instance lock. install.sh names the
/// same folder when it says it leaves the data alone.
enum DataFolder {

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bytemeter", isDirectory: true)
    }

    /// The database the app counts into.
    static var database: URL { database(in: url) }

    /// The database in a folder given on the command line, such as a copy
    /// or a demo, under the same name.
    static func database(in folder: URL) -> URL {
        folder.appendingPathComponent("bytemeter.db")
    }

    /// Held for the life of the app; see `SingleInstance`. Only the app takes
    /// it, because only the app samples.
    static var lock: URL { url.appendingPathComponent("bytemeter.lock") }
}
