import Artwork
import CoreGraphics
import Fixtures
import Foundation
import Metadata

/// The art column's thumbnail of a large cover: a 128-point column on a retina screen.
private let largeCoverPixels = 256
/// Decodes timed per cover, after a warm-up.
private let decodeRuns = 9

private let largeCovers = Result { try makeLargeCovers() }

/// Decoding the biggest covers a real library holds to the art column's size: ImageIO scales a
/// JPEG while it decodes, but decodes a PNG whole (phase 32e).
let artworkBenchmarks = [
    Benchmark(
        name: "art: decode a \(largeCoverSide) px JPEG cover to a column thumbnail (median)",
        budget: Budget(appleSilicon: 30, oldMac: 120, unit: .milliseconds)
    ) {
        try decodeMeasured(jpegMIMEType)
    },
    Benchmark(
        name: "art: decode a \(largeCoverSide) px PNG cover to a column thumbnail (median)",
        budget: Budget(appleSilicon: 150, oldMac: 600, unit: .milliseconds)
    ) {
        try decodeMeasured(pngMIMEType)
    },
]

private func decodeMeasured(_ mimeType: String) throws -> Measured {
    guard let cover = try largeCovers.get().first(where: { $0.mimeType == mimeType }) else {
        throw BenchError.expected("a large \(mimeType) cover")
    }
    var decoded: CGImage?
    let milliseconds = try medianMilliseconds(iterations: decodeRuns) {
        decoded = thumbnail(of: cover.data, maxPixelSize: largeCoverPixels)
    }
    guard let decoded else { throw BenchError.expected("the cover to decode") }
    return Measured(
        value: milliseconds,
        notes: [
            String(
                format: "%.1f MB, to %d×%d px", Double(cover.data.count) / 1e6, decoded.width,
                decoded.height)
        ])
}
