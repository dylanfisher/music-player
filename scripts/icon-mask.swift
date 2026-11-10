// Cuts the app icon's master PNG to its tile, so everything outside the tile is transparent.
// Quick Look renders the SVG on an opaque white square, which the app switcher showed around the
// icon (ADR 0043).
//
//   swift scripts/icon-mask.swift <svg> <png>
//
// The tile is the SVG's `tile` clip path, a rounded rect in the 1024 px canvas; <png> is replaced.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("icon-mask: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: icon-mask.swift <svg> <png>") }
let svgURL = URL(fileURLWithPath: arguments[1], isDirectory: false)
let pngURL = URL(fileURLWithPath: arguments[2], isDirectory: false)
guard let svg = try? String(contentsOf: svgURL, encoding: .utf8) else {
    fail("couldn't read \(svgURL.path)")
}

/// The tile clip path's rect: `<clipPath id="tile"><rect x=… y=… width=… height=… rx=…/>`.
func tileAttribute(_ name: String) -> Double {
    guard
        let clip = svg.range(of: #"<clipPath id="tile"><rect [^>]*>"#, options: .regularExpression),
        let attribute = svg[clip].range(of: #" \#(name)="[0-9.]+""#, options: .regularExpression)
    else { fail("no \(name) on the tile clip path in \(svgURL.path)") }
    let text = svg[attribute].split(separator: "\"")[1]
    guard let value = Double(text) else { fail("\(name)=\"\(text)\" isn't a number") }
    return value
}
let canvas = 1024.0
let tile = CGRect(
    x: tileAttribute("x"), y: canvas - tileAttribute("y") - tileAttribute("height"),
    width: tileAttribute("width"), height: tileAttribute("height"))
let radius = tileAttribute("rx")
// Quick Look blends the tile's antialiased edge with the white around it, so the cut runs a pixel
// inside the edge to leave no light fringe.
let edgeInsetPixels = 1.0

guard let source = CGImageSourceCreateWithURL(pngURL as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fail("couldn't read \(pngURL.path)") }
guard image.width == Int(canvas), image.height == Int(canvas) else {
    fail("\(pngURL.path) is \(image.width)x\(image.height), not \(Int(canvas)) px square")
}
guard
    let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fail("couldn't make a \(image.width) px drawing context") }
context.addPath(
    CGPath(
        roundedRect: tile.insetBy(dx: edgeInsetPixels, dy: edgeInsetPixels),
        cornerWidth: radius - edgeInsetPixels, cornerHeight: radius - edgeInsetPixels,
        transform: nil))
context.clip()
context.draw(image, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
guard let masked = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
        pngURL as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fail("couldn't write \(pngURL.path)") }
CGImageDestinationAddImage(destination, masked, nil)
guard CGImageDestinationFinalize(destination) else { fail("couldn't write \(pngURL.path)") }
