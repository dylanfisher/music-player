import Foundation
import Testing

@testable import Discogs
@testable import Fixtures
@testable import Metadata
@testable import TagWriter

// Get Artwork (ADR 0172): the release's cover for albums tagged with its id, through a stand-in
// transport; only copies in a temp folder are written.

/// The fake's release 1001 serving the fixture generator's 64-pixel JPEG as its image.
private func serving() throws -> (FakeDiscogs, [UInt8]) {
    let jpeg = try #require(try makeArtwork().first { $0.mimeType == jpegMIMEType })
    let fake = FakeDiscogs()
    fake.queue("/front-1001.jpg", status: 200, body: Array(jpeg.data))
    return (fake, Array(jpeg.data))
}

/// Fill Missing covers a file with no art or fewer pixels than the cover and leaves one with
/// as many; Replace covers every file. A release is fetched once for all its albums, and one
/// with no image is a problem that leaves its files alone.
@Test func getArtworkFillsOrReplacesTheFrontCover() async throws {
    let (fake, jpeg) = try serving()
    let api = fake.api()
    let albums = [
        CoverAlbum(title: "A – One", releaseID: 1001, paths: ["/a", "/b", "/c"]),
        CoverAlbum(title: "A – One, disc 2", releaseID: 1001, paths: ["/d"]),
        CoverAlbum(title: "B – None", releaseID: 1006, paths: ["/e"]),
    ]
    let held: [String: Int?] = ["/a": nil, "/b": 63 * 64, "/c": 64 * 64, "/d": 600 * 600]
    let cover = { (id: Int) async -> Result<Cover, CoverProblem> in
        do throws(CoverProblem) {
            return .success(try await api.cover(release: id))
        } catch {
            return .failure(error)
        }
    }
    let filling = await coverPlan(albums, fill: .fillMissing, cover: cover) { held[$0] ?? nil }
    #expect(filling.edits.map(\.path) == ["/a", "/b"])
    #expect(
        filling.edits.allSatisfy {
            $0.edit == TagEdit(art: .replace(Data(jpeg), mimeType: jpegMIMEType))
        })
    #expect(filling.albums == 1)
    #expect(filling.problems == ["B – None: no cover: \(CoverProblem.noImage)"])
    #expect(fake.requests.count { $0.url.path == "/front-1001.jpg" } == 1)

    // A second Get Artwork asks again.
    fake.queue("/front-1001.jpg", status: 200, body: jpeg)
    let replacing = await coverPlan(albums, fill: .replace, cover: cover) { _ in
        Issue.record("Replace reads no art")
        return nil
    }
    #expect(replacing.edits.map(\.path) == ["/a", "/b", "/c", "/d"])
    #expect(replacing.albums == 2)
}

/// A file whose art can't be read is a problem, and the rest are still covered.
@Test func artThatCantBeReadIsAProblem() async throws {
    struct Unreadable: Error {}
    let cover = try Cover(checking: try serving().1)
    let plan = await coverPlan(
        [CoverAlbum(title: "A", releaseID: 1, paths: ["/bad", "/good"])], fill: .fillMissing,
        cover: { _ in .success(cover) }
    ) { path in
        if path == "/bad" { throw Unreadable() }
        return nil
    }
    #expect(plan.edits.map(\.path) == ["/good"])
    #expect(plan.problems.count == 1)
}

/// `artPixels` reads the art a file shows: none, then the cover written to it.
@Test func artPixelsReadsTheArtShown() throws {
    let url = try WrittenSample.flac.copies()[0]
    let writer = TagWriter(
        journal: TagUndoJournal(dataDirectory: url.deletingLastPathComponent()))
    #expect(writer.write(TagEdit(art: .remove), to: [url.path]).failures == [])
    #expect(try artPixels(at: url.path) == nil)
    let cover = try Cover(checking: try serving().1)
    let edit = TagEdit(art: .replace(cover.bytes, mimeType: cover.mimeType))
    #expect(writer.write(edit, to: [url.path]).failures == [])
    #expect(try artPixels(at: url.path) == cover.width * cover.height)
}
