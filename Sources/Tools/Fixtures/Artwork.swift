import CoreGraphics
import Foundation
import ImageIO
import Metadata

/// An embedded cover image.
struct Artwork: Sendable {
    var mimeType: String
    var width: Int
    var height: Int
    var data: Data

    var manifestEntry: FixtureArt {
        FixtureArt(mimeType: mimeType, width: width, height: height, byteCount: data.count)
    }
}

/// A few small covers in both formats taggers embed, rendered once per run.
func makeArtwork() throws -> [Artwork] {
    try [
        (64, "public.jpeg", jpegMIMEType), (300, "public.jpeg", jpegMIMEType),
        (120, "public.png", pngMIMEType),
    ].enumerated().map { index, spec in
        let (side, type, mime) = spec
        return Artwork(
            mimeType: mime, width: side, height: side,
            data: try encodeGradient(side: side, hue: Double(index) / 3, type: type))
    }
}

private func encodeGradient(side: Int, hue: Double, type: String) throws -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
        let gradient = CGGradient(
            colorsSpace: space,
            colors: [
                CGColor(red: hue, green: 0.3, blue: 1 - hue, alpha: 1),
                CGColor(red: 1 - hue, green: 0.8, blue: hue, alpha: 1),
            ] as CFArray, locations: nil)
    else { throw FixtureError.artwork("couldn't create a \(side)×\(side) bitmap") }
    context.drawLinearGradient(
        gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
    let data = NSMutableData()
    guard let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)
    else { throw FixtureError.artwork("couldn't encode a \(side)×\(side) \(type)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw FixtureError.artwork("couldn't encode a \(side)×\(side) \(type)")
    }
    return data as Data
}

/// The side of the largest covers in a real library, which the fixture library's small ones
/// don't show the decode cost of.
public let largeCoverSide = 3000

/// A `largeCoverSide` cover as a JPEG and as a PNG, a gradient with grain, so each compresses
/// about as a scanned photo does: a few MB as JPEG, over 10 MB as PNG.
public func makeLargeCovers() throws -> [(mimeType: String, data: Data)] {
    let side = largeCoverSide
    let space = CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
        let pixels = context.data?.assumingMemoryBound(to: UInt8.self)
    else { throw FixtureError.artwork("couldn't create a \(side)×\(side) bitmap") }
    var random = SplitMix64(seed: UInt64(side))
    for y in 0..<side {
        for x in 0..<side {
            let base = (y * side + x) * 4
            let grain = Int(random.next() & 0x1F) - 16
            for (channel, level) in [x * 255 / side, y * 255 / side, 128].enumerated() {
                pixels[base + channel] = UInt8(clamping: level + grain)
            }
        }
    }
    guard let image = context.makeImage() else {
        throw FixtureError.artwork("couldn't render a \(side)×\(side) cover")
    }
    return try [("public.jpeg", jpegMIMEType), ("public.png", pngMIMEType)].map { type, mime in
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)
        else { throw FixtureError.artwork("couldn't encode a \(side)×\(side) \(type)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.artwork("couldn't encode a \(side)×\(side) \(type)")
        }
        return (mime, data as Data)
    }
}
