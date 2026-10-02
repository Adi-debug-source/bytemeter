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

    /// Estimated bytes are hatched rather than dimmed. A dimmer down bar would
    /// read as an up bar, and on the heatmap a dimmer cell would read as a
    /// quieter hour, which is exactly the false claim the mark exists to stop.
    /// The ground under each hatch is opaque, so a hatched portion looks the
    /// same whatever it is drawn over.
    static let estimatedDownGround = "#163a37"
    static let estimatedUpGround = "#10221f"
    static let estimatedUpStripe = "rgba(53,169,159,0.62)"
    static let heatHatch = "rgba(238,241,243,0.5)"

    /// Hatch patterns for a bar chart. Ids are prefixed per chart because
    /// every inline SVG on the page shares one id space.
    private static func barHatchDefs(_ id: String) -> String {
        """
        <defs>
        <pattern id="\(id)-est-down" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">\
        <rect width="6" height="6" fill="\(estimatedDownGround)"/>\
        <line x1="1.5" y1="0" x2="1.5" y2="6" stroke="\(accent)" stroke-width="2.2"/></pattern>
        <pattern id="\(id)-est-up" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">\
        <rect width="6" height="6" fill="\(estimatedUpGround)"/>\
        <line x1="1.5" y1="0" x2="1.5" y2="6" stroke="\(estimatedUpStripe)" stroke-width="2"/></pattern>
        </defs>
        """
    }

    /// The heatmap's hatch has no ground of its own, so the cell's colour,
    /// which is the hour's whole traffic, still shows through it.
    private static func heatHatchDefs(_ id: String) -> String {
        """
        <defs><pattern id="\(id)-est-heat" width="5" height="5" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">\
        <line x1="1" y1="0" x2="1" y2="5" stroke="\(heatHatch)" stroke-width="1.5"/></pattern></defs>
        """
    }

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

    // MARK: - Bars

    /// Height of each half of a bar chart, in viewBox units.
    private static let barHalfHeight = 84.0
    /// Anything thinner than this is not drawn, so a key is not shown for it.
    private static let minimumBarHeight = 0.4
    private static let minimumBandHeight = 1.0

    /// The axis maximum for a set of bars, shared by the drawing and by
    /// `barsShowEstimate`, so the two can never disagree.
    private static func barScale(_ values: [(label: String, totals: Totals)]) -> Double {
        let peak = values.map { max($0.totals.bytesIn, $0.totals.bytesOut) }.max() ?? 0
        return niceCeiling(Double(max(peak, 1)))
    }

    /// Whether a bar chart will draw any estimated portion thick enough to
    /// see. A day's estimate is often a few MB on a bar of several GB, and a
    /// key for marks nobody can see would only confuse.
    static func barsShowEstimate(_ values: [(label: String, totals: Totals)]) -> Bool {
        let scaleMax = barScale(values)
        return values.contains { entry in
            Double(min(entry.totals.estimatedIn, entry.totals.bytesIn)) / scaleMax * barHalfHeight > minimumBarHeight
                || Double(min(entry.totals.estimatedOut, entry.totals.bytesOut)) / scaleMax * barHalfHeight > minimumBarHeight
        }
    }

    /// Bars above the baseline for down, below it for up, on one shared scale.
    ///
    /// One scale on purpose. Upload is usually a small fraction of download, so
    /// the lower half often looks nearly empty, and that is the truth of it
    /// rather than a flaw. Giving upload its own scale would be a second y axis
    /// pretending the two are comparable.
    ///
    /// Where part of a bar is estimated, the measured part sits next to the
    /// baseline and the estimated part is stacked beyond it, hatched. Bar
    /// heights are unchanged: estimated bytes are real bytes.
    static func mirroredBars(id: String,
                             values: [(label: String, totals: Totals)],
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
        let halfHeight = barHalfHeight
        let labelBand = 22.0
        let baseline = topPad + halfHeight
        let height = topPad + halfHeight * 2 + labelBand

        let scaleMax = barScale(values)
        let slot = plotWidth / Double(count)
        // Capped, so a chart with only two or three bars does not turn them
        // into slabs the width of the page.
        let barWidth = max(2.0, min(slot - 2.0, min(slot * 0.72, 90.0)))

        var svg = """
        <svg viewBox="0 0 \(fmt(width)) \(fmt(height))" role="img" class="chart" preserveAspectRatio="none">
        """
        if values.contains(where: { $0.totals.estimatedTotal > 0 }) { svg += barHatchDefs(id) }

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
            let downEstH = Double(min(entry.totals.estimatedIn, entry.totals.bytesIn)) / scaleMax * halfHeight
            let upEstH = Double(min(entry.totals.estimatedOut, entry.totals.bytesOut)) / scaleMax * halfHeight

            let title = "<title>\(escape(tooltip(index)))</title>"
            svg += "<g class=\"bar\">\(title)"
            // Each half is drawn as measured then estimated, outwards from the
            // baseline. A sliver too thin to see is skipped, as before.
            let downMeasured = downH - downEstH
            if downMeasured > minimumBarHeight {
                svg += """
                <rect x="\(fmt(x))" y="\(fmt(baseline - downMeasured))" width="\(fmt(barWidth))" \
                height="\(fmt(downMeasured))" rx="2" fill="\(accent)"/>
                """
            }
            if downEstH > minimumBarHeight {
                svg += """
                <rect x="\(fmt(x))" y="\(fmt(baseline - downH))" width="\(fmt(barWidth))" \
                height="\(fmt(downEstH))" rx="2" fill="url(#\(id)-est-down)" class="est"/>
                """
            }
            let upMeasured = upH - upEstH
            if upMeasured > minimumBarHeight {
                svg += """
                <rect x="\(fmt(x))" y="\(fmt(baseline + 1))" width="\(fmt(barWidth))" \
                height="\(fmt(upMeasured))" rx="2" fill="\(accentSoft)"/>
                """
            }
            if upEstH > minimumBarHeight {
                svg += """
                <rect x="\(fmt(x))" y="\(fmt(baseline + 1 + max(upMeasured, 0)))" width="\(fmt(barWidth))" \
                height="\(fmt(upEstH))" rx="2" fill="url(#\(id)-est-up)" class="est"/>
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

    // MARK: - Heatmap

    private static let heatCellHeight = 30.0
    private static let heatGap = 2.0

    /// The height of a cell's hatched band: its estimated share of the cell.
    private static func estimateBand(_ cell: HeatCell) -> Double {
        let total = cell.totals.total
        guard total > 0 else { return 0 }
        return Double(min(cell.totals.estimatedTotal, total)) / Double(total) * (heatCellHeight - heatGap)
    }

    static func heatShowsEstimate(_ cells: [HeatCell]) -> Bool {
        cells.contains { estimateBand($0) >= minimumBandHeight }
    }

    /// Weekday against hour of day. The view that shows when the data goes.
    ///
    /// The colour is the whole hour's traffic, estimated or not. The share
    /// that was spread across a gap is hatched up from the bottom of the cell,
    /// so a night the Mac slept through reads as fully hatched rather than as
    /// steady overnight use.
    static func heatmap(id: String, cells: [HeatCell], estimateNote: (HeatCell) -> String) -> String {
        let cellW = 38.0
        let cellH = heatCellHeight
        let gap = heatGap
        let leftPad = 44.0
        let topPad = 20.0
        let width = leftPad + 24 * cellW
        let height = topPad + 7 * cellH + 16

        let peak = cells.map(\.totals.total).max() ?? 0
        var svg = """
        <svg viewBox="0 0 \(fmt(width)) \(fmt(height))" role="img" class="chart heat" preserveAspectRatio="xMidYMid meet">
        """
        if cells.contains(where: { $0.totals.estimatedTotal > 0 }) { svg += heatHatchDefs(id) }

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
                + "up \(Units.bytes(cell.totals.bytesOut))." + estimateNote(cell)
            svg += """
            <g class="cell"><title>\(escape(label))</title>\
            <rect x="\(fmt(x + gap / 2))" y="\(fmt(y + gap / 2))" width="\(fmt(cellW - gap))" \
            height="\(fmt(cellH - gap))" rx="3" fill="\(colour)"/>
            """
            let bandH = estimateBand(cell)
            if bandH >= minimumBandHeight {
                svg += """
                <rect x="\(fmt(x + gap / 2))" y="\(fmt(y + cellH - gap / 2 - bandH))" width="\(fmt(cellW - gap))" \
                height="\(fmt(bandH))" rx="\(fmt(min(3, bandH / 2)))" fill="url(#\(id)-est-heat)" class="est"/>
                """
            }
            svg += "</g>"
        }

        svg += "</svg>"
        return svg
    }

    static func heatLegend(peak: UInt64, estimateKey: String) -> String {
        var swatches = ""
        for colour in heatRamp {
            swatches += "<span class=\"swatch\" style=\"background:\(colour)\"></span>"
        }
        return """
        <div class="legend"><span class="axis">none</span>\(swatches)\
        <span class="axis">\(escape(Units.bytes(peak)))</span>\(estimateKey)</div>
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
