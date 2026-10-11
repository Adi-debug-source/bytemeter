import Foundation

// MARK: - Rules the app layer applies to outside text
//
// In the engine so the self-test can check it directly. It needs only
// Foundation, and the dashboard's CSV export is the only thing that calls it.
// CapInput.swift holds the other such rule, for the cap typed into
// Preferences.

/// One text cell of the CSV export.
public enum CSVCell {

    /// A cell starting with one of these is read by a spreadsheet as a
    /// formula, or has the character skipped before that check. Process names
    /// and network names come from outside, so any of them could be one.
    static let formulaStarts: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]

    /// Quoted, with inner quotes doubled, and with a leading apostrophe on
    /// anything a spreadsheet would treat as a formula, the usual defence
    /// against formula injection. Checked by Unicode scalar, because "\r\n"
    /// is one Character in Swift and would slip past a Character check.
    public static func text(_ value: String) -> String {
        var safe = value
        if let first = safe.unicodeScalars.first, formulaStarts.contains(first) {
            safe = "'" + safe
        }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
