import AppKit
import Foundation
import Testing

@testable import LibraryBrowser
@testable import Metadata

/// A PNG `width` pixels wide, so each picture is told apart by its size.
private func png(width: Int) throws -> Data {
    let rep = try #require(
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 10, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
    return try #require(rep.representation(using: .png, properties: [:]))
}

private func bigEndian(_ value: UInt64, bytes: Int) -> Data {
    Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
}

/// A FLAC file, in a folder of its own, of STREAMINFO and a PICTURE block of each type in
/// `types`, with no audio after them: all the parser reads.
private func flacWithPictures(_ types: [UInt32]) throws -> URL {
    // 44.1 kHz, 2 channels, 16 bits, 4410 samples, then an empty MD5.
    let info =
        bigEndian(4096, bytes: 2) + bigEndian(4096, bytes: 2) + Data(count: 6)
        + bigEndian(44_100 << 44 | 1 << 41 | 15 << 36 | 4410, bytes: 8) + Data(count: 16)
    var blocks: [(type: UInt8, body: Data)] = [(0, info)]
    for (index, type) in types.enumerated() {
        let image = try png(width: 10 * (index + 1))
        let mime = Data("image/png".utf8)
        blocks.append(
            (
                6,
                bigEndian(UInt64(type), bytes: 4) + bigEndian(UInt64(mime.count), bytes: 4) + mime
                    + bigEndian(0, bytes: 4) + Data(count: 16)
                    + bigEndian(UInt64(image.count), bytes: 4) + image
            ))
    }
    var file = Data("fLaC".utf8)
    for (index, block) in blocks.enumerated() {
        file.append(block.type | (index == blocks.count - 1 ? 0x80 : 0))
        file += bigEndian(UInt64(block.body.count), bytes: 3) + block.body
    }
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("art-viewer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("pictures.flac", isDirectory: false)
    try file.write(to: url)
    return url
}

/// A file of three pictures opens on its front cover, and ← and → step through them, stopping
/// at either end, saying which shows (53.3).
@MainActor @Test func theViewerStepsThroughEveryPictureOfAFile() throws {
    let url = try flacWithPictures([4, 3, 6])
    let metadata = try readMetadata(at: url, pictures: true).metadata
    let front = try #require(metadata.art)
    let screen = try #require(NSScreen.main)
    let viewer = ArtViewer(
        image: NSImage(size: NSSize(width: 10, height: 10)), screen: screen, owner: nil)
    var failures: [String] = []
    viewer.show()
    defer { viewer.close() }
    // As `readPictures` hands them over once read: another test's posting that the app
    // resigned active can close this viewer first, which drops the read.
    viewer.show(metadata.pictures, current: front, path: url.path) { failures.append($0) }
    #expect(viewer.pictures.count == 3)
    #expect(viewer.shown == 1)
    #expect(viewer.placeText == "2 of 3 · Front Cover")

    let view = try #require(viewer.window.contentView)
    func press(_ characters: String, _ keyCode: UInt16) throws {
        view.keyDown(
            with: try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .function, timestamp: 0,
                    windowNumber: viewer.window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: keyCode)))
    }
    let right = ("\u{F703}", UInt16(124))
    let left = ("\u{F702}", UInt16(123))
    try press(right.0, right.1)
    #expect(viewer.placeText == "3 of 3 · Disc Label")
    try press(right.0, right.1)
    #expect(viewer.shown == 2, "it stops at the last")
    try press(left.0, left.1)
    try press(left.0, left.1)
    #expect(viewer.placeText == "1 of 3 · Back Cover")
    viewer.step(by: -1)
    #expect(viewer.shown == 0, "and at the first")
    #expect(viewer.window.isVisible)
    #expect(failures.isEmpty)
}

@MainActor @Test func aFileOfOnePictureShowsNoPlace() throws {
    let url = try flacWithPictures([3])
    let metadata = try readMetadata(at: url, pictures: true).metadata
    let art = try #require(metadata.art)
    let viewer = ArtViewer(
        image: NSImage(size: NSSize(width: 10, height: 10)), screen: try #require(NSScreen.main),
        owner: nil)
    viewer.show()
    defer { viewer.close() }
    viewer.show(metadata.pictures, current: art, path: url.path) { Issue.record("\($0)") }
    #expect(viewer.pictures.count == 1)
    #expect(viewer.placeText.isEmpty)
    viewer.step(by: 1)
    #expect(viewer.shown == 0)
}

/// A file whose pictures changed since its row's art was read opens on its first picture, so
/// the picture and the line agree.
@MainActor @Test func artNoLongerInTheFileShowsTheFirstPicture() async throws {
    let url = try flacWithPictures([4, 3])
    let metadata = try readMetadata(at: url, pictures: true).metadata
    let viewer = ArtViewer(
        image: NSImage(size: NSSize(width: 99, height: 99)), screen: try #require(NSScreen.main),
        owner: nil)
    viewer.show()
    defer { viewer.close() }
    let stale = EmbeddedArt(offset: 1, byteCount: 1, mimeType: "image/png", unsynchronised: false)
    viewer.show(metadata.pictures, current: stale, path: url.path) { Issue.record("\($0)") }
    #expect(viewer.shown == 0)
    #expect(viewer.placeText == "1 of 2 · Back Cover")
    // The first picture is 10 pixels wide, the opening image 99 points. Another test's posting
    // that the app resigned active closes the viewer and drops the decode, so it's waited for
    // only while the viewer is open.
    try await waitFor("the first picture") {
        !viewer.window.isVisible || viewer.image?.size.width != 99
    }
    if viewer.window.isVisible { #expect(viewer.image?.size.width == 10) }
}
