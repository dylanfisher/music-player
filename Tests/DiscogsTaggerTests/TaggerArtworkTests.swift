import AppKit
import Foundation
import Testing

@testable import Discogs
@testable import DiscogsTagger
@testable import Settings

@MainActor
@Test func theArtworkRowNeedsATokenAndOKKeepsItsMode() throws {
    let without = MappingSheet(
        draft: MappingDraft(mapping: DiscogsPreset.minimal.mapping, saved: []), artwork: .off,
        hasToken: false)
    #expect(!without.artworkPopUp.isEnabled)
    #expect(without.artworkNote.stringValue == MappingSheet.needsTokenNote)
    let with = MappingSheet(
        draft: MappingDraft(mapping: DiscogsPreset.minimal.mapping, saved: []),
        artwork: .fillEmpty, hasToken: true)
    #expect(with.artworkPopUp.isEnabled)
    #expect(with.artworkPopUp.itemArray.map(\.title) == ["Off", "Fill Empty", "Replace All"])
    #expect(with.artworkPopUp.indexOfSelectedItem == 1)
    with.artworkPopUp.selectItem(at: 2)
    _ = with.artworkPopUp.target?.perform(with.artworkPopUp.action, with: with.artworkPopUp)
    with.okButton.performClick(nil)
    #expect(with.result != nil)
    #expect(with.artwork == .replace)
    without.window?.close()
    with.window?.close()
}

private let stockholm = ["Östermalm", "Gamla Stan", "Kungsholmen"]
private let albums = [
    album(1, "Stockholm", titles: stockholm), album(2, "Other", titles: stockholm),
]

/// A cover as the API's would be, of a few bytes nothing decodes: the model only passes it on.
private let fakeCover = Cover(
    bytes: Data([0xFF, 0xD8, 0xFF, 0xD9]), mimeType: "image/jpeg", width: 600, height: 600)

/// A model of `albums`, each Exact, with `artwork` and `token`, covers from `cover`.
@MainActor
private func artworkModel(
    _ artwork: DiscogsArtworkMode, token: Bool, asked: Asked,
    cover: @escaping @Sendable (Int) -> Result<Cover, CoverProblem>
) async -> TaggerModel {
    let tagger = await model(
        Seen(), albums: albums,
        matches: { album, _ in
            match(album, release(Int(album.id) * 10, album.title, titles: stockholm), tier: .exact)
        },
        files: { ids in
            albums.flatMap { album in album.tracks.indices.map { file(album, $0) } }
                .filter { ids.contains($0.id) }
        },
        choices: TaggerChoices(
            keepExistingValues: false, skipVideo: true, fillSortArtist: false, artwork: artwork),
        cover: { id in
            asked.add(id)
            return cover(id)
        })
    tagger.hasToken = { token }
    tagger.analyze()
    await tagger.finished()
    return tagger
}

/// The releases a cover was asked for.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Int] = []
    func add(_ id: Int) { lock.withLock { ids.append(id) } }
    var all: [Int] { lock.withLock { ids } }
}

@MainActor
@Test func applyCountsTheCoversAndWritesThemWithTheTagsInOneBatch() async throws {
    let asked = Asked()
    let tagger = await artworkModel(.replace, token: true, asked: asked) { _ in .success(fakeCover)
    }
    let plan = try #require(await tagger.plan([1, 2]))
    #expect(plan.coverCount == 6)
    #expect(plan.files.count == 6)
    #expect(
        plan.files.allSatisfy { $0.edit.art == .replace(fakeCover.bytes, mimeType: "image/jpeg") })
    #expect(plan.files.allSatisfy { !$0.edit.values.isEmpty || !$0.edit.custom.isEmpty })
    let (message, detail) = TaggerModel.confirmation(plan)
    #expect(message == "Change \(plan.fieldCount) tags and 6 covers in 6 files of 2 albums?")
    #expect(detail.contains("primary image from Discogs"))
    #expect(asked.all.sorted() == [10, 20])
    // A second plan asks Discogs nothing more.
    _ = await tagger.plan([1, 2])
    #expect(asked.all.count == 2)
}

@MainActor
@Test func aCoverThatCantBeHadIsAProblemOfItsAlbumAndTheTagsStillApply() async throws {
    let asked = Asked()
    let tagger = await artworkModel(.replace, token: true, asked: asked) { id in
        id == 10 ? .failure(.damaged) : .success(fakeCover)
    }
    let plan = try #require(await tagger.plan([1, 2]))
    #expect(plan.albumIDs.sorted() == [1, 2])
    #expect(plan.files.count == 6)
    #expect(plan.coverCount == 3)
    #expect(plan.problems == ["Persuader – Stockholm: no cover: the image is damaged or cut short"])
    #expect(plan.files.filter { $0.path.hasPrefix("/m/1/") }.allSatisfy { $0.edit.art == nil })
}

@MainActor
@Test func withoutATokenOrWithArtworkOffNoCoverIsAskedFor() async throws {
    for (mode, token) in [(DiscogsArtworkMode.replace, false), (.off, true)] {
        let asked = Asked()
        let tagger = await artworkModel(mode, token: token, asked: asked) { _ in
            .success(fakeCover)
        }
        let plan = try #require(await tagger.plan([1, 2]))
        #expect(plan.coverCount == 0)
        #expect(plan.files.allSatisfy { $0.edit.art == nil })
        #expect(asked.all.isEmpty, "\(mode) \(token)")
        #expect(!TaggerModel.confirmation(plan).message.contains("cover"))
    }
}

@MainActor
@Test func aCoverUntickedInViewChangesIsLeftOut() async throws {
    let asked = Asked()
    let tagger = await artworkModel(.fillEmpty, token: true, asked: asked) { _ in
        .success(fakeCover)
    }
    let (set, problems) = try #require(try await tagger.changeSet(for: 1))
    #expect(problems.isEmpty)
    let sheet = ChangesSheet(set: set, excluded: [], title: "Stockholm", releaseID: 10)
    guard case .cover(let cover, let adds, let replaces) = sheet.rows.first else {
        Issue.record("no cover row: \(sheet.rows)")
        return
    }
    #expect(cover == fakeCover)
    #expect((adds, replaces) == (3, 0))
    #expect(sheet.text(.written, 0) == "600 × 600 JPEG from Discogs")
    sheet.toggle(0)
    #expect(sheet.coverExcluded)
    tagger.setExcluded([], coverExcluded: true, for: 1)
    let plan = try #require(await tagger.plan([1]))
    #expect(plan.coverCount == 0)
    #expect(plan.files.allSatisfy { $0.edit.art == nil })
    sheet.window?.close()
}

@Test func theArtworkSettingIsOffUntilChosenAndKeptBesideTheMapping() throws {
    let schema = AppSettings()
    #expect(schema.discogsArtwork.defaultValue == .off)
    #expect(DiscogsArtworkMode.allCases.map(\.rawValue) == ["off", "fillEmpty", "replace"])
    // Not a field of the mapping: a saved mapping without it still reads.
    #expect(!DiscogsField.allCases.map(\.rawValue).contains("artwork"))
}
