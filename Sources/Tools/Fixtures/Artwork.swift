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
