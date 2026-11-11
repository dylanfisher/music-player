import AppKit
import Foundation
import Testing

@testable import BarView
@testable import Fixtures
@testable import Library
@testable import Metadata
@testable import TagEditor
@testable import TagWriter

private func track(_ path: String, plays: Int?, readOnly: String? = nil) -> EditableTrack {
    EditableTrack(path: path, tags: TrackTags(), pictures: [], readOnly: readOnly, playCount: plays)
}

/// The Plays field shows the count the tracks share, "Mixed" where they differ, and goes to
/// every track the index has, read-only files included (ADR 0162).
@Test func thePlayCountIsSharedOrMixedAndGoesToEveryCountedTrack() throws {
    var model = TagEditorModel(tracks: [
        track("/a.dsf", plays: 3, readOnly: "DSF tags can't be written"),
        track("/b.flac", plays: 3), track("/c.flac", plays: nil),
    ])
    #expect(model.playCountText == "3")
    #expect(!model.isPlayCountMixed)
    #expect(model.countedPaths == ["/a.dsf", "/b.flac"])
    #expect(model.playCountChange == nil)
    model.setPlayCount("3")
    #expect(!model.isPlayCountEdited, "typed back to what it showed")
    #expect(model.playCountChange == nil)
    model.setPlayCount("12")
    #expect(model.isPlayCountEdited)
    try model.checkPlayCount()
    #expect(model.playCountChange == 12)

    let mixed = TagEditorModel(tracks: [track("/a.flac", plays: 1), track("/b.flac", plays: 2)])
    #expect(mixed.isPlayCountMixed)
    #expect(mixed.playCountText.isEmpty)

    let readOnly = TagEditorModel(tracks: [track("/a.dsf", plays: 0, readOnly: "no")])
    #expect(!readOnly.canSave)
    #expect(readOnly.canSaveAnything, "its count can still be set")
    #expect(!TagEditorModel(tracks: [track("/a.flac", plays: nil, readOnly: "no")]).canSaveAnything)
}

@Test func aPlayCountThatIsntOneIsRefused() {
    for bad in ["", "-1", "1.5", "ten", "２", "2147483648"] {
        var model = TagEditorModel(tracks: [track("/a.flac", plays: 3)])
        model.setPlayCount(bad)
        #expect(throws: PlayCountError.self, "\(bad)") { try model.checkPlayCount() }
    }
}

/// The window's Plays field shows the index's count, can be typed in for read-only files, and
/// Save refuses a bad count on the window's line.
@MainActor @Test func theFileTabsPlaysField() throws {
    let editor = TagEditorWindow(paths: ["/a.dsf"])
    defer { editor.close() }
    editor.load(TagEditorModel(tracks: [track("/a.dsf", plays: 7, readOnly: "DSF")]))
    #expect(editor.playCountField.stringValue == "7")
    #expect(editor.playCountField.isEditable)
    #expect(editor.saveButton.isEnabled)
    var saved: [TagEdit] = []
    editor.saved = { saved.append($0) }
    editor.playCountField.stringValue = "x"
    editor.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: editor.playCountField))
    click(editor.saveButton)
    #expect(saved.isEmpty)
    #expect(editor.problemLabel.stringValue.contains("isn't a whole number"))
    editor.playCountField.stringValue = "9"
    editor.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: editor.playCountField))
    click(editor.saveButton)
    #expect(saved.count == 1)
    #expect(editor.model?.playCountChange == 9)
}

/// What the fakes saw, from the main actor.
@MainActor
private final class Seen {
    var written: [[String]] = []
    var counts: [(Int, [String])] = []
    var ratings: [(Int, [String])] = []
    /// What the index has, by path, as the stand-in for it answers.
    var indexRatings: [String: Int] = ["/a.flac": 2]
    var confirmations = 0
}

@MainActor
private func makeEditing(_ seen: Seen, confirm: Bool = true) -> TagEditing {
    let editing = TagEditing(
        effects: .init(
            read: { paths, _ in
                (paths.map { EditableTrack(path: $0, tags: TrackTags(), pictures: []) }, [])
            },
            write: { files, _, _ in
                var report = TagWriteReport()
                report.changed = files.map(\.path)
                return report
            },
            undo: { _ in TagWriteReport() }, newestEdit: { nil }, present: { _, _ in },
            confirm: { _, _, answer in
                seen.confirmations += 1
                answer(confirm)
            },
            alert: { _, _, _ in }, layout: { _, _ in FilesOrganized() },
            move: { plan, _, _, _ in plan }, follow: { _ in [] },
            askQuit: { _, _ in Issue.record("asked to quit") }))
    editing.written = { report, _, _ in seen.written.append(report.changed) }
    editing.playCounts = { paths in paths.map { $0 == "/none.flac" ? nil : 5 } }
    editing.setPlayCount = { seen.counts.append(($0, $1)) }
    editing.ratings = { paths in paths.map { seen.indexRatings[$0] } }
    editing.setRating = { seen.ratings.append(($0, $1)) }
    return editing
}

@MainActor
private func loaded(_ editing: TagEditing, _ paths: [String]) async throws -> TagEditorWindow {
    let window = NSWindow()
    editing.open(paths, over: window)
    let deadline = Date().addingTimeInterval(waitLimit)
    while editing.editors.first(where: { $0.paths == paths })?.isLoaded != true {
        try #require(Date() < deadline, "timed out reading \(paths)")
        try await Task.sleep(for: .milliseconds(5))
    }
    return try #require(editing.editors.first { $0.paths == paths })
}

/// The read gives each track its count from the index; Save stores a count typed alone with
/// no write, and with tags only once the batch question is answered yes.
@MainActor @Test func saveStoresTheCountWithoutAWrite() async throws {
    let seen = Seen()
    let editing = makeEditing(seen)
    let alone = try await loaded(editing, ["/a.flac", "/none.flac"])
    #expect(alone.model?.tracks.map(\.playCount) == [5, nil])
    #expect(alone.playCountField.stringValue == "5")
    alone.playCountField.stringValue = "20"
    alone.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: alone.playCountField))
    alone.saved(try #require(alone.model).edit())
    #expect(seen.counts.map(\.0) == [20])
    #expect(seen.counts.map(\.1) == [["/a.flac"]], "the track the index lacks is left out")
    try await Task.sleep(for: .milliseconds(50))
    #expect(seen.written.isEmpty)
    #expect(!editing.isOpen)

    let declining = makeEditing(seen, confirm: false)
    let batch = try await loaded(declining, ["/a.flac", "/b.flac"])
    batch.playCountField.stringValue = "1"
    batch.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: batch.playCountField))
    batch.saved(TagEdit(values: [.album: "Both"]))
    #expect(seen.confirmations == 1)
    #expect(seen.counts.count == 1, "declined, so the count waits with the tags")
    #expect(declining.isOpen)
    batch.close()
}

/// The read gives each track its rating from the index; a click on the stars rates at once,
/// only the tracks the index has, with no write; a rating set elsewhere shows.
@MainActor @Test func theStarsRateInTheIndexAtOnce() async throws {
    let seen = Seen()
    let editing = makeEditing(seen)
    let editor = try await loaded(editing, ["/a.flac", "/none.flac"])
    #expect(editor.model?.tracks.map(\.rating) == [2, nil])
    #expect(editor.ratingStars.rating == 2)
    let width = editor.ratingStars.intrinsicContentSize.width / 5
    editor.ratingStars.click(atX: width * 4.5)
    #expect(seen.ratings.map(\.0) == [5])
    #expect(seen.ratings.map(\.1) == [["/a.flac"]])
    try await Task.sleep(for: .milliseconds(50))
    #expect(seen.written.isEmpty)
    seen.indexRatings["/a.flac"] = 1
    editing.ratingsChanged()
    #expect(editor.ratingStars.rating == 1)
    editor.close()
}
