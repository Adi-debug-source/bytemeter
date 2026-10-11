import Foundation

/// Writes one line to standard error. Run as the login item, that is
/// `~/Library/Logs/Bytemeter/bytemeter.err` (see Scripts/bytemeter.plist); run
/// from a terminal, it is the terminal. The engine reports a failed
/// transaction the same way, through `Database.log`.
func logError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
