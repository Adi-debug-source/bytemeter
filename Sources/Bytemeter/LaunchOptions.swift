import Foundation
import BytemeterCore

/// The command line.
///
/// With none of its own flags Bytemeter is the menu bar app, which is how the
/// login item and Finder start it, and anything else the system passes along
/// is ignored. Once one of its flags is present, the line is read strictly and
/// a mistake is reported rather than half followed.
struct LaunchOptions {

    enum Mode: Equatable {
        case app
        case help
        /// Build the dashboard from a database and exit. Nil means the app's
        /// own data folder.
        case dashboard(folder: String?)
        /// Show the real menu bar item and menu for a demo database.
        case demo(folder: String)
    }

    struct UsageError: Error {
        let message: String
    }

    let mode: Mode
    /// The moment to work everything out as of, if not now.
    let asOf: Date?

    static let usage = """
    Bytemeter counts this Mac's network traffic from the menu bar.

    Usage:
      Bytemeter
          Run the menu bar app. This is how the login item starts it.

      Bytemeter --dashboard [folder] [--as-of TIME]
          Build dashboard.html and bytemeter_export.csv from the database in the
          folder, then exit. The folder defaults to Bytemeter's own data folder.

      Bytemeter --demo <folder> [--as-of TIME]
          Show the real menu bar item and its real menu, drawn from the database
          in the folder, until you choose Quit from that menu. It exists for
          screenshots: pointed at a database made by Scripts/make_demo_db.py, it
          shows the app's actual menu without anyone's real figures or app names.
          It is read only. It never writes, never samples, never touches the real
          data folder, and leaves a running Bytemeter undisturbed. Open dashboard
          and Preferences do nothing in it, because both would write.

    TIME is a local date and time, for example 2026-10-02T21:30. Everything is
    worked out as if it were that moment: today, the week and the month, the
    hourly chart, peaks, projections and all time stop there, and anything
    recorded after it is ignored.
    """

    private static let flags: Set<String> = ["--dashboard", "--demo", "--as-of", "--help", "-h"]

    static func parse(_ arguments: [String], calendar: BytemeterCalendar = BytemeterCalendar())
        -> Result<LaunchOptions, UsageError> {
        let args = Array(arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            return .success(LaunchOptions(mode: .help, asOf: nil))
        }
        let dashboard = args.firstIndex(of: "--dashboard")
        let demo = args.firstIndex(of: "--demo")
        let asOfFlag = args.firstIndex(of: "--as-of")
        guard dashboard != nil || demo != nil || asOfFlag != nil else {
            return .success(LaunchOptions(mode: .app, asOf: nil))
        }

        // From here the line is meant for Bytemeter, so read it strictly.
        func value(after index: Int) -> String? {
            let next = index + 1
            guard next < args.count, !args[next].hasPrefix("-") else { return nil }
            return args[next]
        }
        if dashboard != nil && demo != nil {
            return .failure(UsageError(message: "Use --dashboard or --demo, not both."))
        }
        var consumed = Set([dashboard, demo, asOfFlag].compactMap { $0 })

        var asOf: Date?
        if let index = asOfFlag {
            guard let text = value(after: index) else {
                return .failure(UsageError(message: "--as-of needs a time, for example 2026-10-02T21:30."))
            }
            guard let date = calendar.parseLocal(text) else {
                return .failure(UsageError(message: "--as-of wants a local time such as 2026-10-02T21:30, not \"\(text)\"."))
            }
            asOf = date
            consumed.insert(index + 1)
        }

        let mode: Mode
        if let index = dashboard {
            let folder = value(after: index)
            if folder != nil { consumed.insert(index + 1) }
            mode = .dashboard(folder: folder)
        } else if let index = demo {
            guard let folder = value(after: index) else {
                return .failure(UsageError(message: "--demo needs the folder that holds the demo database."))
            }
            consumed.insert(index + 1)
            mode = .demo(folder: folder)
        } else {
            return .failure(UsageError(message: "--as-of goes with --dashboard or --demo."))
        }

        for (index, arg) in args.enumerated() where !consumed.contains(index) {
            let known = flags.contains(arg) ? "" : " Unknown option."
            return .failure(UsageError(message: "Did not expect \"\(arg)\".\(known)"))
        }
        return .success(LaunchOptions(mode: mode, asOf: asOf))
    }
}
