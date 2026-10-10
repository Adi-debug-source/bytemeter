import Foundation

/// Decimal units throughout, because that is how ISPs and routers count.
/// 1 kB = 1,000 bytes, 1 MB = 1,000,000, 1 GB = 1,000,000,000.
/// Never binary units anywhere in this app.
public enum Units {
    public static let kB: Double = 1_000
    public static let MB: Double = 1_000_000
    public static let GB: Double = 1_000_000_000

    /// A byte count as text. `compact` is the narrow form for the menu bar,
    /// which trades a decimal place for a steadier width.
    ///
    /// Each rule falls through to the next once its rounding reaches the
    /// next rule's threshold, so 999,600 bytes reads 1.0 MB, not 1000 kB,
    /// and 9.996 GB reads 10.0 GB, not 10.00 GB.
    public static func bytes(_ value: UInt64, compact: Bool = false) -> String {
        let v = Double(value)
        if v < kB { return "\(value) B" }
        if v < MB {
            let k = v / kB
            if k < 10 && !compact, let text = printed(k, "%.1f kB", below: 10) { return text }
            if let text = printed(k, "%.0f kB", below: 1000) { return text }
        }
        if v < GB {
            let m = v / MB
            if compact {
                if let text = printed(m, "%.0f MB", below: 1000) { return text }
            } else {
                if m < 100, let text = printed(m, "%.1f MB", below: 100) { return text }
                if let text = printed(m, "%.0f MB", below: 1000) { return text }
            }
        }
        let g = v / GB
        if compact { return String(format: "%.1f GB", g) }
        if g < 10, let text = printed(g, "%.2f GB", below: 10) { return text }
        return String(format: "%.1f GB", g)
    }

    /// A transfer rate: whole numbers below 1 MB/s, one decimal in MB/s and
    /// two in GB/s. Like `bytes`, it moves up a unit rather than print 1000.
    public static func rate(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        if v < kB, let text = printed(v, "%.0f B/s", below: 1000) { return text }
        if v < MB, let text = printed(v / kB, "%.0f kB/s", below: 1000) { return text }
        if v < GB, let text = printed(v / MB, "%.1f MB/s", below: 1000) { return text }
        return String(format: "%.2f GB/s", v / GB)
    }

    /// `value` printed with `format`, or nil if the printed number has
    /// rounded up to `limit`, where the rule for the larger figure takes over.
    /// The printed text is what is checked, so the rounding is exactly the
    /// one shown.
    private static func printed(_ value: Double, _ format: String, below limit: Double) -> String? {
        let text = String(format: format, value)
        let number = Double(text.prefix { $0 != " " }) ?? 0
        return number < limit ? text : nil
    }

    /// Bytes as a bare decimal number of GB, for chart axes and CSV.
    public static func gigabytes(_ value: UInt64) -> Double { Double(value) / GB }
}
