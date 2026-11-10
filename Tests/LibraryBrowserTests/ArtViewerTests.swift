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

/// A file of several pictures shows a thumbnail of each along the bottom, the art above them,
/// and a click on one shows it; one picture has no strip (phase 66).
@MainActor @Test func severalPicturesShowAStripOfThumbnails() async throws {
    let url = try flacWithPictures([3, 4, 6])
    let metadata = try readMetadata(at: url, pictures: true).metadata
    let viewer = ArtViewer(
        image: NSImage(size: NSSize(width: 10, height: 10)), screen: try #require(NSScreen.main),
        owner: nil)
    viewer.show()
    defer { viewer.close() }
    viewer.show(metadata.pictures, current: try #require(metadata.art), path: url.path) {
        Issue.record("\($0)")
    }
    #expect(viewer.thumbnailButtons.count == 3)
    let strip = try #require(viewer.thumbnailButtons.first?.superview)
    viewer.window.contentView?.layoutSubtreeIfNeeded()
    #expect(viewer.imageFrame.minY >= strip.frame.maxY, "the art is above the strip")
    // Another test's posting that the app resigned active closes the viewer and drops the
    // decodes, so they're waited for only while it's open.
    try await waitFor("the thumbnails") {
        !viewer.window.isVisible || viewer.thumbnails.allSatisfy { $0 != nil }
    }
    guard viewer.window.isVisible else { return }
    #expect(viewer.thumbnails.map { $0?.size.width } == [10, 20, 30])
    let button = viewer.thumbnailButtons[2]
    button.sendAction(button.action, to: button.target)
    #expect(viewer.placeText == "3 of 3 · Disc Label")

    let single = try flacWithPictures([3])
    let one = try readMetadata(at: single, pictures: true).metadata
    viewer.show(one.pictures, current: try #require(one.art), path: single.path) {
        Issue.record("\($0)")
    }
    #expect(viewer.thumbnailButtons.isEmpty)
}

/// The decoded art is drawn at most a point a pixel: a picture 10 pixels square stays 10
/// points, though the art it opened with filled the screen.
@MainActor @Test func theViewerDoesntEnlargeArtPastItsPixels() async throws {
    let url = try flacWithPictures([3])
    let art = try #require(try readMetadata(at: url, pictures: true).metadata.art)
    let viewer = ArtViewer(
        image: NSImage(size: NSSize(width: 4, height: 4)), screen: try #require(NSScreen.main),
        owner: nil)
    viewer.show()
    defer { viewer.close() }
    #expect(viewer.imageFrame.width > 4, "the opening art fills the screen until the decode")
    await viewer.load(art, path: url.path) { Issue.record("\($0)") }.value
    guard viewer.window.isVisible else { return }
    #expect(viewer.imageFrame.size == CGSize(width: 10, height: 10))
}

/// The viewer shows only once it's at its final layout: the art decoded at its own size and
/// the strip's room kept, a button a picture, before the thumbnails decode, so nothing moves
/// as they fill in (phase 70).
@MainActor @Test func theViewerOpensAtItsFinalLayout() async throws {
    let url = try flacWithPictures([4, 3, 6])
    let front = try #require(try readMetadata(at: url, pictures: true).metadata.art)
    let viewer = ArtViewer(
        image: NSImage(size: NSSize(width: 4, height: 4)), screen: try #require(NSScreen.main),
        owner: nil)
    defer { viewer.close() }
    let opening = Task { await viewer.open(front, path: url.path) { Issue.record("\($0)") } }
    #expect(!viewer.window.isVisible, "nothing shows before the art and the pictures are read")
    await opening.value
    // Another test's posting that the app resigned active closes the viewer, which then
    // never shows.
    guard !viewer.isClosed else { return }
    #expect(viewer.window.isVisible)
    #expect(viewer.image?.size == CGSize(width: 20, height: 10), "the front cover, decoded")
    #expect(viewer.thumbnailButtons.count == 3)
    #expect(viewer.placeText == "2 of 3 · Front Cover")
    let opened = viewer.imageFrame
    #expect(opened.size == CGSize(width: 20, height: 10))
    try await waitFor("the thumbnails") {
        viewer.isClosed || viewer.thumbnails.allSatisfy { $0 != nil }
    }
    guard !viewer.isClosed else { return }
    viewer.window.contentView?.layoutSubtreeIfNeeded()
    #expect(viewer.imageFrame == opened, "the thumbnails fill in place")
}

/// A viewer closed while it opens, as by the owner window closing, never shows.
@MainActor @Test func aViewerClosedWhileItOpensNeverShows() async throws {
    let url = try flacWithPictures([3])
    let art = try #require(try readMetadata(at: url, pictures: true).metadata.art)
    let viewer = ArtViewer(
        image: NSImage(size: NSSize(width: 4, height: 4)), screen: try #require(NSScreen.main),
        owner: nil)
    var closed = 0
    viewer.closed = { closed += 1 }
    let opening = Task { await viewer.open(art, path: url.path) { Issue.record("\($0)") } }
    viewer.close()
    await opening.value
    #expect(!viewer.window.isVisible)
    #expect(closed == 1)
}
