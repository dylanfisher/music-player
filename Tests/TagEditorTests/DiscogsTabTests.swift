import AppKit
import Foundation
import Testing

@testable import Discogs
@testable import Metadata
@testable import TagEditor
@testable import TagWriter

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
    #expect(model.shownReleaseIDs == [42, 7])
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

/// Waits a few seconds for `condition`.
@MainActor
private func waitFor(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        try #require(Date() < deadline, "timed out waiting for \(what)")
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// A save that gives the files a release id, or changes it, reads the new release; a read for
/// the old one that finishes late is dropped. The tab stays throughout.
@MainActor @Test func aRereadShowsTheReleaseTheFilesHoldNow() async throws {
    let editor = TagEditorWindow(paths: ["/music/a.flac"])
    defer { editor.close() }
    var held: CheckedContinuation<Void, Never>?
    editor.release = { id in
        if id == 42 { await withCheckedContinuation { held = $0 } }
        var detail = stockholm
        detail.summary.id = id
        detail.summary.title = "Release \(id)"
        return detail
    }
    editor.load(TagEditorModel(tracks: [track("a", release: nil)]))
    #expect(editor.shownTabs == TagEditorTab.allCases)
    #expect(editor.discogsText.string == noReleaseText)

    editor.load(TagEditorModel(tracks: [track("a", release: "42")]))
    #expect(editor.discogsReleaseID == 42)
    try await waitFor("the read of 42") { held != nil }
    editor.load(TagEditorModel(tracks: [track("a", release: "7")]))
    #expect(editor.discogsReleaseID == 7)
    try await waitFor("release 7") { editor.discogsText.string.contains("Release 7") }
    held?.resume()
    held = nil
    try await Task.sleep(for: .milliseconds(50))
    #expect(editor.discogsText.string.contains("Release 7"), "the late read of 42 is dropped")

    editor.load(TagEditorModel(tracks: [track("a", release: nil)]))
    #expect(editor.shownTabs == TagEditorTab.allCases)
    #expect(editor.discogsReleaseID == nil)
    #expect(editor.discogsText.string == noReleaseText)
}

/// Every window has the tab, read from the catalog when the files have a release id, with
/// Open on Discogs; files with none say how to give them one (phase 57).
@MainActor @Test func everyWindowHasTheTab() async throws {
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
    try await waitFor("the release") { tagged.discogsText.string == stockholm.text }
    #expect(asked == [42])
    #expect(!tagged.discogsText.isEditable)
    #expect(tagged.releaseIDField.stringValue == "42")
    tagged.openOnDiscogs()
    #expect(opened == [discogsPage(42)])

    let untagged = TagEditorWindow(paths: ["/music/b.flac"])
    defer { untagged.close() }
    untagged.load(TagEditorModel(tracks: [track("b", release: nil)]))
    #expect(untagged.shownTabs == TagEditorTab.allCases)
    #expect(untagged.discogsReleaseID == nil)
    #expect(untagged.releaseIDField.stringValue.isEmpty)
}

/// A release id typed on the tab goes to every file as the Extras key, and the tab reads that
/// release; files that differ show "Mixed" until it's typed.
@MainActor @Test func aReleaseIdTypedIsSavedAndRead() async throws {
    let editor = TagEditorWindow(paths: ["/music/a.flac", "/music/b.flac"])
    defer { editor.close() }
    editor.release = { id in
        var detail = stockholm
        detail.summary.title = "Release \(id)"
        return detail
    }
    editor.load(
        TagEditorModel(tracks: [track("a", release: "42"), track("b", release: nil)]))
    #expect(editor.releaseIDField.stringValue.isEmpty)
    #expect(editor.releaseIDField.placeholderString == mixedPlaceholder)

    editor.releaseIDField.stringValue = "1234"
    editor.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: editor.releaseIDField))
    #expect(editor.discogsReleaseID == 1234)
    try await waitFor("release 1234") { editor.discogsText.string.contains("Release 1234") }
    let model = try #require(editor.model)
    #expect(try model.edit().custom == [DiscogsKey.releaseID: "1234"])
    #expect(model.extras.first { $0.key == DiscogsKey.releaseID }?.isEdited == true)
}

/// An id that isn't a whole number above 0 is refused before anything is written; empty
/// removes the key.
@Test func aReleaseIdThatIsntOneIsRefused() throws {
    for bad in ["abc", "0", "-3", "12a", "１２"] {
        var model = TagEditorModel(tracks: [track("a", release: "42")])
        model.setExtra(DiscogsKey.releaseID, bad)
        #expect(model.shownReleaseIDs.isEmpty)
        #expect(throws: TagValueError.self, "\(bad)") { try model.edit() }
    }
    var cleared = TagEditorModel(tracks: [track("a", release: "42")])
    cleared.setExtra(DiscogsKey.releaseID, "")
    #expect(try cleared.edit().custom == [DiscogsKey.releaseID: ""])
}

/// A release id deleted in Extras shows as none on the Discogs tab, and an id typed there
/// afterwards replaces it rather than the delete removing it.
@Test func anIdTypedAfterExtrasDeletedTheKeyReplacesIt() throws {
    var model = TagEditorModel(tracks: [track("a", release: "42")])
    model.deleteExtra(DiscogsKey.releaseID)
    #expect(model.releaseIDText.isEmpty)
    #expect(!model.isReleaseIDMixed)
    #expect(model.shownReleaseIDs.isEmpty)
    #expect(try model.edit().custom == [DiscogsKey.releaseID: ""])
    model.setExtra(DiscogsKey.releaseID, "7")
    #expect(model.releaseIDText == "7")
    #expect(model.extras.map(\.key) == [DiscogsKey.releaseID])
    #expect(try model.edit().custom == [DiscogsKey.releaseID: "7"])
}
