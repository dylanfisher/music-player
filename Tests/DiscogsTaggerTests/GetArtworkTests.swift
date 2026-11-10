import AppKit
import Foundation
import Testing

@testable import Discogs
@testable import DiscogsTagger
@testable import Library
@testable import Metadata
@testable import TagWriter

// Get Artwork (ADR 0172): the front covers of albums tagged with a release id, asked once with
// the count, fetched through the stand-in cover effect and handed to the writer.

private let titles = ["Östermalm", "Gamla Stan"]
private let tagged = album(1, "Stockholm", titles: titles, releaseID: "1001")
private let untagged = album(2, "Other", titles: titles)

private let cover = Cover(
    bytes: Data([0xFF, 0xD8, 0xFF, 0xD9]), mimeType: "image/jpeg", width: 600, height: 600)

/// A tagger over the two albums, both Exact, whose files are at `/m/<file id>` and whose art
/// is as large as `pixels` says.
@MainActor
private func artworkTagger(
    token: Bool = true, pixels: @escaping @Sendable (String) -> Int? = { _ in nil }
) async -> DiscogsTagger {
    let made = await model(
        Seen(), albums: [tagged, untagged],
        matches: { album, _ in
            match(album, release(Int(album.id) * 10, album.title, titles: titles), tier: .exact)
        },
        cover: { $0 == 1001 ? .success(cover) : .failure(.noImage) },
        paths: { ids in Dictionary(uniqueKeysWithValues: ids.map { ($0, "/m/\($0)") }) },
        pixels: { pixels($0) })
    made.hasToken = { token }
    made.analyze()
    await made.finished()
    return DiscogsTagger(model: made)
}

/// The window's Get Artwork covers the albums listed whose files carry a release id, each
/// file its tagged release; an album written this session counts with the release written.
@MainActor @Test func getArtworkCoversTheAlbumsTaggedWithARelease() async throws {
    let tagger = await artworkTagger()
    #expect(
        tagger.model.artworkGroups
            == [ArtworkGroup(title: "Persuader – Stockholm", releaseID: 1001, fileIDs: [100, 101])])
    let window = TaggerWindow(model: tagger.model)
    window.refresh()
    #expect(window.artworkButton.title == "Get Artwork for 1 Album…")
    #expect(window.artworkButton.isEnabled)
    #expect(
        TaggerModel.artworkGroups(untagged, written: 20)
            == [ArtworkGroup(title: "Persuader – Other", releaseID: 20, fileIDs: [200, 201])])
}

/// The groups are kept between refreshes, and made again when an album changes: written by
/// Apply, it counts; rejected, it doesn't.
@MainActor @Test func theArtworkCountFollowsAChangeOfTheAlbums() async throws {
    let tagger = await artworkTagger()
    let window = TaggerWindow(model: tagger.model)
    defer { window.window?.close() }
    window.write = { _, _, _ in }
    window.refresh()
    #expect(window.artworkButton.title == "Get Artwork for 1 Album…")

    tagger.model.apply(
        TaggerModel.ApplyPlan(
            albumIDs: [2], files: [(path: "/m/200", edit: TagEdit())], fieldCount: 1,
            problems: []))
    #expect(tagger.model.artworkGroups.map(\.releaseID) == [1001, 20])
    #expect(window.artworkButton.title == "Get Artwork for 2 Albums…")

    await tagger.model.setRejected(true, [1])
    #expect(tagger.model.artworkGroups.map(\.releaseID) == [20])
    #expect(window.artworkButton.title == "Get Artwork for 1 Album…")
}

/// It asks once, with the count; Fill Missing writes the cover to the files without art or
/// with smaller art, as one batch, and Cancel writes nothing.
@MainActor @Test func getArtworkAsksThenWritesTheFrontCovers() async throws {
    let tagger = await artworkTagger(pixels: { $0 == "/m/101" ? 600 * 600 : 100 * 100 })
    var asked: [String] = []
    var answer: CoverFill? = .fillMissing
    tagger.askArtwork = { question, _, reply in
        asked.append(question.message)
        reply(answer)
    }
    var written: [[(path: String, edit: TagEdit)]] = []
    tagger.write = { files, _, _, _ in written.append(files) }
    var alerts: [String] = []
    tagger.artworkAlert = { message, _, _ in alerts.append(message) }
    var shown: [String?] = []
    let window = NSWindow()
    tagger.getArtwork(tagger.model.artworkGroups, over: window) { shown.append($0?.text) }
    try await eventually { !written.isEmpty }
    #expect(asked == ["Get Artwork for 1 Album?"])
    #expect(written.first?.map(\.path) == ["/m/100"])
    #expect(
        written.first?.first?.edit == TagEdit(art: .replace(cover.bytes, mimeType: jpegMIMEType)))
    #expect(shown.first == "Getting covers: 0 of 1")
    #expect(shown.last == .some(nil), "the progress clears")
    #expect(alerts.isEmpty)

    answer = nil
    tagger.getArtwork(tagger.model.artworkGroups, over: window) { _ in }
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(written.count == 1, "Cancel writes nothing")
}

/// Without a token it says so and asks nothing; the library's Get Discogs Artwork covers only
/// the selected tracks' files that carry a release id.
@MainActor @Test func getArtworkNeedsATokenAndTakesTheSelection() async throws {
    let without = await artworkTagger(token: false)
    var alerts: [String] = []
    without.artworkAlert = { message, _, _ in alerts.append(message) }
    without.askArtwork = { _, _, _ in Issue.record("asked without a token") }
    without.getArtwork(without.model.artworkGroups, over: NSWindow()) { _ in }
    #expect(alerts == ["Get Artwork needs a Discogs token"])

    let tagger = await artworkTagger()
    var written: [String] = []
    tagger.askArtwork = { _, _, reply in reply(.replace) }
    tagger.write = { files, _, _, _ in written += files.map(\.path) }
    tagger.getArtwork(forTracks: [101, 200], over: NSWindow()) { _ in }
    try await eventually { !written.isEmpty }
    #expect(written == ["/m/101"])
}
