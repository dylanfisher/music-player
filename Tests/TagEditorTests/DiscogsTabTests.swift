import AppKit
import Foundation
import Testing

@testable import Discogs
@testable import Metadata
@testable import TagEditor

private func track(_ name: String, release: String?) -> EditableTrack {
    var tags = TrackTags()
    tags.custom[DiscogsKey.releaseID] = release
    return EditableTrack(path: "/music/\(name).flac", tags: tags, art: nil)
}

private let stockholm = ReleaseDetail(
    summary: ReleaseSummary(
        id: 42, artist: "Persuader", title: "Stockholm", label: "Svek", catalogNumber: "SK 032",
        country: "Sweden", year: "1999", format: "CD (Album)", trackCount: 1),
    tracks: [ReleaseDetail.Track(position: "1", title: "Östermalm", seconds: 285)])

@Test func theTabShowsTheFirstReleaseIdOfTheFilesEachOnce() {
    let model = TagEditorModel(tracks: [
        track("a", release: "42"), track("b", release: nil), track("c", release: "7"),
        track("d", release: "42"), track("e", release: "r9"),
    ])
    #expect(model.discogsReleaseIDs == [42, 7])
    #expect(TagEditorModel(tracks: [track("a", release: nil)]).discogsReleaseIDs.isEmpty)
}

/// The release as the catalog has it, or why not; files from several releases say how many
/// others (53.11).
@Test func theTabSaysWhatTheCatalogHas() {
    #expect(discogsTabText(.success(stockholm), releases: 1) == stockholm.text)
    #expect(
        discogsTabText(.success(stockholm), releases: 3)
            == "The first of the files' releases, and 2 other releases.\n\n" + stockholm.text)
    #expect(
        discogsTabText(.success(stockholm), releases: 2)
            == "The first of the files' releases, and 1 other release.\n\n" + stockholm.text)
    #expect(
        discogsTabText(.success(nil), releases: 1) == "This release isn't in the local catalog.")
    #expect(
        discogsTabText(.failure(CatalogError.missing("/x/discogs.sqlite")), releases: 2)
            == "No Discogs catalog is imported.")
}

/// Files with a release id get the tab, read from the catalog, with Open on Discogs; files
/// with none don't.
@MainActor @Test func onlyFilesWithAReleaseIdHaveTheTab() async throws {
    let tagged = TagEditorWindow(paths: ["/music/a.flac"])
    defer { tagged.close() }
    var asked: [Int] = []
    tagged.release = { id in
        asked.append(id)
        return stockholm
    }
    var opened: [URL] = []
    tagged.openURL = { opened.append($0) }
    #expect(tagged.shownTabs.last == .discogs)
    tagged.load(TagEditorModel(tracks: [track("a", release: "42")]))
    #expect(tagged.shownTabs.contains(.discogs))
    let deadline = Date().addingTimeInterval(5)
    while tagged.discogsText.string != stockholm.text {
        try #require(Date() < deadline, "timed out: \(tagged.discogsText.string)")
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(asked == [42])
    #expect(!tagged.discogsText.isEditable)
    tagged.openOnDiscogs()
    #expect(opened == [discogsPage(42)])

    let untagged = TagEditorWindow(paths: ["/music/b.flac"])
    defer { untagged.close() }
    untagged.load(TagEditorModel(tracks: [track("b", release: nil)]))
    #expect(!untagged.shownTabs.contains(.discogs))
    #expect(untagged.shownTabs.count == TagEditorTab.allCases.count - 1)
}
