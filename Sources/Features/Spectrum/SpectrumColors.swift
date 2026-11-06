import Analysis
import AppKit

/// The spectrogram's dB color scale, from black at `Spectrogram.floorDB` through blue, purple,
/// red and orange to white at 0 dB, as Spek draws it: one RGBA entry per 8-bit cell value.
enum SpectrumColors {
    private static let stops: [(at: Double, red: Double, green: Double, blue: Double)] = [
        (0, 0, 0, 0), (0.15, 0, 0, 0.4), (0.35, 0.5, 0, 0.6), (0.55, 0.9, 0.1, 0.2),
        (0.75, 1, 0.55, 0), (0.9, 1, 0.9, 0.2), (1, 1, 1, 1),
    ]

    /// 256 entries of red, green, blue and alpha bytes.
    static let table: [UInt8] = (0..<256).flatMap { cell -> [UInt8] in
        let place = Double(cell) / 255
        let upper = stops.firstIndex { $0.at >= place } ?? stops.count - 1
        let lower = max(0, upper - 1)
        let span = stops[upper].at - stops[lower].at
        let mix = span > 0 ? (place - stops[lower].at) / span : 0
        func channel(
            _ value: KeyPath<(at: Double, red: Double, green: Double, blue: Double), Double>
        )
            -> UInt8
        {
            let level =
                stops[lower][keyPath: value] * (1 - mix) + stops[upper][keyPath: value] * mix
            return UInt8((level * 255).rounded())
        }
        return [channel(\.red), channel(\.green), channel(\.blue), 255]
    }

    static func color(cell: UInt8) -> NSColor {
        let start = Int(cell) * 4
        return NSColor(
            srgbRed: CGFloat(table[start]) / 255, green: CGFloat(table[start + 1]) / 255,
            blue: CGFloat(table[start + 2]) / 255, alpha: 1)
    }

    /// One color per compared file, in the order they're listed.
    static let files: [NSColor] = [
        .systemBlue, .systemOrange, .systemGreen, .systemRed, .systemPurple, .systemTeal,
        .systemPink, .systemYellow,
    ]

    /// `spectrogram` as an image, a pixel per cell, the lowest row at the bottom.
    static func image(_ spectrogram: Spectrogram) -> CGImage? {
        let width = spectrogram.columns
        let height = Spectrogram.rows
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for column in 0..<width {
            for row in 0..<height {
                let cell = Int(spectrogram.cells[column * height + row]) * 4
                let pixel = ((height - 1 - row) * width + column) * 4
                pixels[pixel..<pixel + 4] = table[cell..<cell + 4]
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
