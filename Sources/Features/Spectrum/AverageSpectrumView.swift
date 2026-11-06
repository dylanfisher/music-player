import Analysis
import AppKit

/// Every file's average spectrum on one chart, frequency up as in the spectrograms beside it,
/// level across from the scale's floor to 0 dB, one color per file.
final class AverageSpectrumView: FrequencyAxisView {
    var spectrograms: [Spectrogram?] = [] {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = plot
        NSColor.textBackgroundColor.setFill()
        plot.fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: plot).stroke()
        func x(_ decibels: Double) -> CGFloat {
            plot.minX + plot.width * CGFloat(1 - min(1, max(0, decibels / Spectrogram.floorDB)))
        }
        for (index, spectrogram) in spectrograms.enumerated() {
            guard let spectrogram else { continue }
            let path = NSBezierPath()
            for row in 0..<Spectrogram.rows {
                let hertz = (Double(row) + 0.5) * spectrogram.nyquistHz / Double(Spectrogram.rows)
                let point = NSPoint(x: x(Double(spectrogram.averageDB[row])), y: y(hertz))
                if row == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.lineWidth = 1.5
            SpectrumColors.files[index].setStroke()
            path.stroke()
        }
        for decibels in [Spectrogram.floorDB, Spectrogram.floorDB / 2, 0] {
            let label = NSAttributedString(
                string: decibels == 0 ? "0 dB" : String(format: "%.0f", decibels),
                attributes: Self.labelAttributes)
            let width = label.size().width
            label.draw(
                at: NSPoint(
                    x: min(plot.maxX - width, max(plot.minX, x(decibels) - width / 2)), y: 1))
        }
        drawFrequencyAxis(lineColor: NSColor.tertiaryLabelColor)
    }
}

/// The dB color scale as a bar, with its ends and middle labeled.
final class DecibelScaleView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: 0, y: 14, width: bounds.width, height: 12)
        let steps = max(1, Int(bar.width))
        for step in 0..<steps {
            SpectrumColors.color(cell: UInt8(255 * step / max(1, steps - 1))).setFill()
            NSRect(x: bar.minX + CGFloat(step), y: bar.minY, width: 1, height: bar.height).fill()
        }
        for decibels in [Spectrogram.floorDB, Spectrogram.floorDB / 2, 0] {
            let label = NSAttributedString(
                string: String(format: "%.0f dB", decibels),
                attributes: FrequencyAxisView.labelAttributes)
            let width = label.size().width
            let x = bar.width * CGFloat(1 - decibels / Spectrogram.floorDB)
            label.draw(at: NSPoint(x: min(bar.maxX - width, max(0, x - width / 2)), y: 0))
        }
    }
}
