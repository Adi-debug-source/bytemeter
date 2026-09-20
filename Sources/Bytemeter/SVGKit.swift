import Foundation
import BytemeterCore

/// Hand rolled inline SVG. Nothing here fetches anything: a tool whose whole job
/// is measuring data use must not spend data drawing its own charts, and the
/// dashboard has to render with the Wi-Fi switched off.
enum SVGKit {

    // The palette, validated against the dark surface before a line was drawn.
    // One accent, used at different strengths. Down is the accent at full
    // strength, up is the same hue held back, because down is the headline.
    static let accent = "#35a99f"
    static let accentSoft = "rgba(53,169,159,0.45)"
    static let ink = "#eef1f3"
    static let ink2 = "#a8b1b8"
    static let muted = "#6d777e"
    static let grid = "#23282c"

    /// Sequential ramp for the heatmap, one hue, lightness climbing. The
    /// near zero step is allowed to sink towards the surface, which is what
    /// tells you at a glance where nothing happens.
    static let heatRamp = ["#141a1d", "#123a38", "#14514c", "#176a62", "#1e8479", "#35a99f", "#5cc4b9"]

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// Round an axis maximum up to something a person would choose, so the
    /// quarter gridlines land on readable figures rather than on 114 MB.
    static func niceCeiling(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        let normalised = value / magnitude
        let step: Double
        switch normalised {
        case ...1: step = 1
        case ...2: step = 2
        case ...2.5: step = 2.5
        case ...5: step = 5
        default: step = 10
        }
        return step * magnitude
    }

    /// One decimal at most, and no trailing ".0", for axis ticks.
    static func axisLabel(_ bytes: Double) -> String {
        func trim(_ value: Double) -> String {
            let rounded = (value * 10).rounded() / 10
            return rounded == rounded.rounded()
                ? String(format: "%.0f", rounded)
                : String(format: "%.1f", rounded)
        }
        if bytes >= Units.GB { return trim(bytes / Units.GB) + " GB" }
        if bytes >= Units.MB { return trim(bytes / Units.MB) + " MB" }
        if bytes >= Units.kB { return trim(bytes / Units.kB) + " kB" }
        return "\(Int(bytes)) B"
    }

    /// Bars above the baseline for down, below it for up, on one shared scale.
    ///
    /// One scale on purpose. Upload is usually a small fraction of download, so
    /// the lower half often looks nearly empty, and that is the truth of it
    /// rather than a flaw. Giving upload its own scale would be a second y axis
    /// pretending the two are comparable.
    static func mirroredBars(values: [(label: String, totals: Totals)],
                             labelEvery: Int,
                             rollingAverage: [Double?]? = nil,
                             tooltip: (Int) -> String) -> String {
        let count = max(values.count, 1)
        let width = 1000.0
        let leftPad = 52.0
        let rightPad = 12.0
        let topPad = 14.0
        let plotWidth = width - leftPad - rightPad
        // Equal halves, and the same pixels per byte above and below the line.
        // Giving upload a squeezed half would be a second y axis in disguise,
        // and upload genuinely does outrun download at times (a backup, a video call).
        let halfHeight = 84.0
        let labelBand = 22.0
        let baseline = topPad + halfHeight
        let height = topPad + halfHeight * 2 + labelBand

        let peak = values.map { max($0.totals.bytesIn, $0.totals.bytesOut) }.max() ?? 0
        let scaleMax = niceCeiling(Double(max(peak, 1)))
        let slot = plotWidth / Double(count)
        // Capped, so a chart with only two or three bars does not turn them
        // into slabs the width of the page.
        let barWidth = max(2.0, min(slot - 2.0, min(slot * 0.72, 90.0)))

        var svg = """
        <svg viewBox="0 0 \(fmt(width)) \(fmt(height))" role="img" class="chart" preserveAspectRatio="none">
        """

        // Gridlines, deliberately recessive. Mirrored above and below with the
        // same values, so the shared scale is visible rather than asserted.
        for fraction in [0.5, 1.0] {
            for direction in [-1.0, 1.0] {
                let y = baseline - halfHeight * fraction * direction
                svg += """
                <line x1="\(fmt(leftPad))" y1="\(fmt(y))" x2="\(fmt(width - rightPad))" y2="\(fmt(y))" \
                stroke="\(grid)" stroke-width="1"/>
                <text x="\(fmt(leftPad - 8))" y="\(fmt(y + 3.5))" text-anchor="end" class="axis">\
                \(escape(axisLabel(scaleMax * fraction)))</text>
                """
            }
        }
        svg += """
        <line x1="\(fmt(leftPad))" y1="\(fmt(baseline))" x2="\(fmt(width - rightPad))" y2="\(fmt(baseline))" \
        stroke="#383f45" stroke-width="1"/>
        <text x="\(fmt(leftPad - 8))" y="\(fmt(baseline + 3.5))" text-anchor="end" class="axis">0</text>
        """

        for (index, entry) in values.enumerated() {
            let x = leftPad + slot * Double(index) + (slot - barWidth) / 2
            let downH = Double(entry.totals.bytesIn) / scaleMax * halfHeight
            let upH = Double(entry.totals.bytesOut) / scaleMax * halfHeight

            let title = "<title>\(escape(tooltip(index)))</title>"
            svg += "<g class=\"bar\">\(title)"
            if downH > 0.4 {
                svg += """
                <rect x="\(fmt(x))" y="\(fmt(baseline - downH))" width="\(fmt(barWidth))" \
                height="\(fmt(downH))" rx="2" fill="\(accent)"/>
                """
            }
            if upH > 0.4 {
                svg += """
                <rect x="\(fmt(x))" y="\(fmt(baseline + 1))" width="\(fmt(barWidth))" \
                height="\(fmt(upH))" rx="2" fill="\(accentSoft)"/>
                """
            }
            // An invisible full height target, so hovering anywhere in the
            // column shows the figures rather than only on the bar itself.
            svg += """
            <rect x="\(fmt(leftPad + slot * Double(index)))" y="\(fmt(topPad))" width="\(fmt(slot))" \
            height="\(fmt(halfHeight * 2))" fill="transparent"/></g>
            """
        }

        if let averages = rollingAverage {
            var points: [String] = []
            for (index, value) in averages.enumerated() {
                guard let value, value > 0 else { continue }
                let x = leftPad + slot * Double(index) + slot / 2
                let y = baseline - min(value / scaleMax, 1.0) * halfHeight
                points.append("\(fmt(x)),\(fmt(y))")
            }
            if points.count > 1 {
                svg += """
                <polyline points="\(points.joined(separator: " "))" fill="none" stroke="\(ink)" \
                stroke-width="2" stroke-dasharray="5 4" stroke-linejoin="round" stroke-linecap="round" opacity="0.85"/>
                """
            }
        }

        for (index, entry) in values.enumerated() where index % labelEvery == 0 {
            let x = leftPad + slot * Double(index) + slot / 2
            svg += """
            <text x="\(fmt(x))" y="\(fmt(height - 6))" text-anchor="middle" class="axis">\
            \(escape(entry.label))</text>
            """
        }

        svg += "</svg>"
        return svg
    }

    /// Weekday against hour of day. The view that shows when the data goes.
    static func heatmap(cells: [HeatCell]) -> String {
        let cellW = 38.0
        let cellH = 30.0
        let gap = 2.0
        let leftPad = 44.0
        let topPad = 20.0
        let width = leftPad + 24 * cellW
        let height = topPad + 7 * cellH + 16

        let peak = cells.map(\.totals.total).max() ?? 0
        var svg = """
        <svg viewBox="0 0 \(fmt(width)) \(fmt(height))" role="img" class="chart heat" preserveAspectRatio="xMidYMid meet">
        """

        for hour in stride(from: 0, to: 24, by: 3) {
            let x = leftPad + Double(hour) * cellW + cellW / 2
            svg += """
            <text x="\(fmt(x))" y="12" text-anchor="middle" class="axis">\(String(format: "%02d", hour))</text>
            """
        }

        for (index, name) in BytemeterCalendar.weekdayNames.enumerated() {
            let y = topPad + Double(index) * cellH + cellH / 2 + 4
            svg += """
            <text x="\(fmt(leftPad - 10))" y="\(fmt(y))" text-anchor="end" class="axis">\(name)</text>
            """
        }

        for cell in cells {
            let x = leftPad + Double(cell.hour) * cellW
            let y = topPad + Double(cell.weekday) * cellH
            let fraction = peak == 0 ? 0 : Double(cell.totals.total) / Double(peak)
            // Step 0 means no traffic at all; anything above zero lands in 1 to 6.
            let step = fraction <= 0 ? 0 : min(heatRamp.count - 1, max(1, Int((fraction * Double(heatRamp.count - 1)).rounded(.up))))
            let colour = heatRamp[step]
            let label = "\(BytemeterCalendar.weekdayNames[cell.weekday]) \(String(format: "%02d", cell.hour)):00 to "
                + "\(String(format: "%02d", (cell.hour + 1) % 24)):00, down \(Units.bytes(cell.totals.bytesIn)), "
                + "up \(Units.bytes(cell.totals.bytesOut))"
            svg += """
            <g class="cell"><title>\(escape(label))</title>\
            <rect x="\(fmt(x + gap / 2))" y="\(fmt(y + gap / 2))" width="\(fmt(cellW - gap))" \
            height="\(fmt(cellH - gap))" rx="3" fill="\(colour)"/></g>
            """
        }

        svg += "</svg>"
        return svg
    }

    static func heatLegend(peak: UInt64) -> String {
        var swatches = ""
        for colour in heatRamp {
            swatches += "<span class=\"swatch\" style=\"background:\(colour)\"></span>"
        }
        return """
        <div class="legend"><span class="axis">none</span>\(swatches)\
        <span class="axis">\(escape(Units.bytes(peak)))</span></div>
        """
    }

    /// One horizontal bar split two ways. The idle share carries a hatch as well
    /// as a lighter fill, so the split does not rest on colour alone.
    static func splitBar(activeBytes: UInt64, idleBytes: UInt64) -> String {
        let total = Double(activeBytes &+ idleBytes)
        let width = 1000.0
        let height = 34.0
        guard total > 0 else {
            return """
            <svg viewBox="0 0 \(fmt(width)) \(fmt(height))" class="chart" preserveAspectRatio="none">\
            <rect x="0" y="6" width="\(fmt(width))" height="22" rx="4" fill="\(grid)"/></svg>
            """
        }
        let activeWidth = Double(activeBytes) / total * width
        return """
        <svg viewBox="0 0 \(fmt(width)) \(fmt(height))" class="chart" preserveAspectRatio="none">
        <defs><pattern id="hatch" width="8" height="8" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
        <rect width="8" height="8" fill="rgba(53,169,159,0.18)"/>
        <line x1="0" y1="0" x2="0" y2="8" stroke="\(accent)" stroke-width="2.5" opacity="0.6"/></pattern></defs>
        <g><title>Active, someone at the keyboard: \(escape(Units.bytes(activeBytes)))</title>
        <rect x="0" y="6" width="\(fmt(max(activeWidth - 1, 0)))" height="22" rx="4" fill="\(accent)"/></g>
        <g><title>Idle, no input for five minutes or more: \(escape(Units.bytes(idleBytes)))</title>
        <rect x="\(fmt(activeWidth + 1))" y="6" width="\(fmt(max(width - activeWidth - 1, 0)))" height="22" rx="4" fill="url(#hatch)"/></g>
        </svg>
        """
    }
}
