import Foundation

// MARK: - Rules the app layer applies to outside text
//
// In the engine so the self-test can check it directly. It needs only
// Foundation, and the macOS app is the only thing that calls it.
// CSVCell.swift holds the other such rule, for the cells of the CSV export.

/// The monthly cap as typed into Preferences.
public enum CapInput {

    /// No monthly allowance comes near 100,000 GB, and keeping below it means
    /// the conversion to bytes can never overflow.
    public static let largestGigabytes: Int64 = 100_000
    public static let bytesPerGigabyte: Int64 = 1_000_000_000
    public static let largestBytes: Int64 = largestGigabytes * bytesPerGigabyte

    /// Typed text to a cap in bytes, never above `largestBytes` and never
    /// below zero, and never a trap whatever is typed. Whole or decimal
    /// gigabytes, with an optional "GB" after and commas between thousands.
    /// A number too long to hold is simply above the largest, so it becomes
    /// the largest. Anything else, a sign, an exponent, "inf", is no cap at all.
    ///
    /// Read as a decimal, digit by digit, never through a floating point
    /// number: a run of 400 digits is just a whole part longer than the
    /// largest has, and a fraction is exact to the byte, so what the field
    /// shows back (`text(forBytes:)`) is exactly what was stored.
    public static func bytes(fromText text: String) -> Int64 {
        var digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.lowercased().hasSuffix("gb") {
            digits = String(digits.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        digits = digits.replacingOccurrences(of: ",", with: "")
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard !digits.isEmpty, parts.count <= 2,
              digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              digits.contains(where: { $0.isNumber })
        else { return 0 }

        // The whole gigabytes. Leading zeros mean nothing; more digits than
        // the largest has can only be above it.
        let whole = parts[0].drop { $0 == "0" }
        let wholeDigits = String(largestGigabytes).count
        guard whole.count <= wholeDigits, let gigabytes = Int64(whole.isEmpty ? "0" : String(whole)),
              gigabytes < largestGigabytes
        else { return largestBytes }

        // The fraction, to the byte: nine digits, rounded on the tenth.
        let fraction = parts.count == 2 ? Array(parts[1]) : []
        var fractionBytes: Int64 = 0
        for index in 0..<9 {
            fractionBytes = fractionBytes * 10 + (index < fraction.count ? Int64(String(fraction[index]))! : 0)
        }
        if fraction.count > 9, let next = Int64(String(fraction[9])), next >= 5 { fractionBytes += 1 }
        return clamp(gigabytes * bytesPerGigabyte + fractionBytes)
    }

    /// A saved figure, which may have been written by anything, brought into range.
    public static func clamp(_ bytes: Int64) -> Int64 { min(max(bytes, 0), largestBytes) }

    /// What the field shows for a saved cap: "100", "1.5", "0.001", or empty
    /// for none. Exact, to the byte, so it always reads back as what is
    /// stored and typing it again stores the same figure.
    public static func text(forBytes bytes: Int64) -> String {
        let value = clamp(bytes)
        guard value > 0 else { return "" }
        let whole = String(value / bytesPerGigabyte)
        var fraction = String(value % bytesPerGigabyte)
        fraction = String(repeating: "0", count: 9 - fraction.count) + fraction
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return fraction.isEmpty ? whole : whole + "." + fraction
    }
}
