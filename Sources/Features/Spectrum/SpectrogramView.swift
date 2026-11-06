import Analysis
import AppKit
import DisplayText

/// One file's spectrogram: time across, frequency up to the axis's top, each cell in the dB
/// color scale. Above the file's own Nyquist frequency, where a file at a lower rate has
/// nothing, the plot is left gray. Drawn in AppKit, as the Listening Stats charts are.
final class SpectrogramView: FrequencyAxisView {
    var spectrogram: Spectrogram? {
        didSet {
            image = spectrogram.flatMap(SpectrumColors.image)
            needsDisplay = true
        }
    }
    private var image: CGImage?

    override func draw(_ dirtyRect: NSRect) {
        let plot = plot
        NSColor.quaternaryLabelColor.setFill()
        plot.fill()
        if let spectrogram, let image, let context = NSGraphicsContext.current?.cgContext {
            var drawn = plot
            drawn.size.height = y(spectrogram.nyquistHz) - plot.minY
            context.interpolationQuality = .medium
            context.draw(image, in: drawn)
            let start = NSAttributedString(string: clock(0), attributes: Self.labelAttributes)
            start.draw(at: NSPoint(x: plot.minX, y: 1))
            let end = NSAttributedString(
                string: clock(spectrogram.durationSeconds), attributes: Self.labelAttributes)
            end.draw(at: NSPoint(x: plot.maxX - end.size().width, y: 1))
        }
        drawFrequencyAxis(lineColor: NSColor.white.withAlphaComponent(0.6))
    }
}
