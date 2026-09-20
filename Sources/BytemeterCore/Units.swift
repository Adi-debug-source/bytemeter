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
    public static func bytes(_ value: UInt64, compact: Bool = false) -> String {
        let v = Double(value)
        if v < kB { return "\(value) B" }
        if v < MB {
            let k = v / kB
            return k < 10 && !compact ? String(format: "%.1f kB", k) : String(format: "%.0f kB", k)
        }
        if v < GB {
            let m = v / MB
            if compact { return String(format: "%.0f MB", m) }
            return m < 100 ? String(format: "%.1f MB", m) : String(format: "%.0f MB", m)
        }
        let g = v / GB
        if compact { return String(format: "%.1f GB", g) }
        return g < 10 ? String(format: "%.2f GB", g) : String(format: "%.1f GB", g)
    }

    /// A transfer rate. Always one decimal so the menu bar width stays put.
    public static func rate(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        if v < kB { return String(format: "%.0f B/s", v) }
        if v < MB { return String(format: "%.0f kB/s", v / kB) }
        if v < GB { return String(format: "%.1f MB/s", v / MB) }
        return String(format: "%.2f GB/s", v / GB)
    }

    /// Bytes as a bare decimal number of GB, for chart axes and CSV.
    public static func gigabytes(_ value: UInt64) -> Double { Double(value) / GB }
}
