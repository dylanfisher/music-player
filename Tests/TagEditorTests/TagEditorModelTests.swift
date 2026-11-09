import Foundation
import Testing

@testable import Metadata
@testable import TagEditor
@testable import TagWriter

private func track(_ name: String, album: String?, number: Int?, art: Data? = nil) -> EditableTrack
{
    var tags = TrackTags()
    tags.title = name
    tags.album = album
    tags.trackNumber = number
    return EditableTrack(path: "/music/\(name).flac", tags: tags, pictures: frontCovers(art))
}

@Test func sharedValuesShowAndDifferingOnesAreMixed() {
    let model = TagEditorModel(tracks: [
        track("A", album: "Same", number: 1), track("B", album: "Same", number: 2),
    ])
    #expect(model.text(.album) == "Same")
    #expect(!model.isMixed(.album))
    #expect(model.isMixed(.title))
    #expect(model.text(.title) == "")
    #expect(model.shared(.composer) == "", "no track has one, which isn't mixed")
    #expect(!model.isMixed(.composer))
}

@Test func onlyFieldsTypedDifferentlyAreInTheEdit() throws {
    var model = TagEditorModel(tracks: [
        track("A", album: "Same", number: 1), track("B", album: "Same", number: 2),
    ])
    model.set(.album, "Same")
    model.set(.title, "Both")
    model.set(.composer, "")
    #expect(try model.edit() == TagEdit(values: [.title: "Both"]))
    #expect(!model.isMixed(.title))
    model.set(.album, "")
    #expect(try model.edit().values[.album] == "", "clearing a shared value is an edit")
}

@Test func aMixedFieldTypedEmptyClearsItEverywhere() throws {
    var model = TagEditorModel(tracks: [
        track("A", album: "X", number: 1), track("B", album: "Y", number: 2),
    ])
    model.set(.album, "")
    #expect(try model.edit().values == [.album: ""])
}

@Test func badNumbersAreCaughtBeforeSaving() {
    var model = TagEditorModel(tracks: [track("A", album: nil, number: 1)])
    model.set(.trackNumber, "two")
    #expect(throws: TagValueError.self) { try model.edit() }
}

@Test func artIsSharedMixedReplacedOrRemoved() throws {
    let cover = Data([1, 2, 3])
    var model = TagEditorModel(tracks: [
        track("A", album: nil, number: nil, art: cover),
        track("B", album: nil, number: nil, art: cover),
    ])
    #expect(model.shownArt == cover)
    #expect(model.canRemoveArt)
    model.removeArt()
    #expect(model.shownArt == nil)
    #expect(!model.canRemoveArt)
    #expect(try model.edit().art == .remove)
    model.replaceArt(Data([9]), mimeType: pngMIMEType)
    #expect(try model.edit().art == .replace(Data([9]), mimeType: pngMIMEType))

    let mixed = TagEditorModel(tracks: [
        track("A", album: nil, number: nil, art: cover), track("B", album: nil, number: nil),
    ])
    #expect(mixed.isArtMixed)
    #expect(mixed.shownArt == nil)
    #expect(try mixed.edit().art == nil)
}

@Test func unreadableFilesAreReportedAndTheRestOpen() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "tageditor-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let junk = folder.appendingPathComponent("junk.mp3")
    try Data("not audio".utf8).write(to: junk)
    let (tracks, problems) = readEditableTracks([
        junk.path, folder.appendingPathComponent("gone.flac").path,
    ])
    #expect(tracks.isEmpty)
    #expect(problems.count == 2)
}

/// The reads made, and the most running at once.
private final class ReadCount: @unchecked Sendable {
    // Every field is guarded by `lock`.
    private let lock = NSLock()
    private var running = 0
    private(set) var most = 0
    private(set) var reads = 0

    func read(_ path: String) throws -> EditableTrack {
        lock.withLock {
            reads += 1
            running += 1
            most = max(most, running)
        }
        defer { lock.withLock { running -= 1 } }
        // Long enough for every reader to start, as each waits on the NAS.
        Thread.sleep(forTimeInterval: 0.05)
        guard !path.hasSuffix("bad") else { throw MetadataError(unreadable: path, detail: "bad") }
        return track(path, album: nil, number: nil)
    }
}

// Dispatch runs one thread at a time on a single core, so only the order shows there.
@Test(.enabled(if: ProcessInfo.processInfo.activeProcessorCount > 1))
func filesAreReadAFewAtOnceAndKeepTheirOrder() {
    let paths = (0..<(filesReadAtOnce * 3)).map { $0 == 4 ? "\($0) bad" : "\($0)" }
    let count = ReadCount()
    let (tracks, problems) = readEditableTracks(paths, read: { try count.read($0) })
    #expect(count.most == min(filesReadAtOnce, paths.count))
    #expect(tracks.map(\.tags.title) == paths.filter { !$0.hasSuffix("bad") })
    #expect(problems.count == 1)
}

@Test func fewerFilesThanTheLimitAreEachReadOnce() {
    let paths = ["a", "b bad"]
    let count = ReadCount()
    let (tracks, problems) = readEditableTracks(paths, read: { try count.read($0) })
    #expect(count.most <= paths.count)
    #expect(count.reads == paths.count)
    #expect(tracks.map(\.tags.title) == ["a"])
    #expect(problems.count == 1)
}

@Test func noFilesReadNothing() {
    let count = ReadCount()
    let (tracks, problems) = readEditableTracks([], read: { try count.read($0) })
    #expect(count.reads == 0)
    #expect(tracks.isEmpty && problems.isEmpty)
}

@Test func editingAFieldWithSeveralValuesSaysOnlyOneIsKept() {
    var several = track("A", album: "X", number: 1)
    several.multiValued = [.artist]
    var model = TagEditorModel(tracks: [several, track("B", album: "X", number: 2)])
    #expect(model.collapseNote == nil, "nothing edited yet")
    model.set(.album, "Y")
    #expect(model.collapseNote == nil, "the album holds one value")
    model.set(.artist, "Both")
    #expect(model.collapsedFields == [.artist])
    #expect(
        model.collapseNote
            == "Artist holds several values in 1 file. Saving keeps only the value shown.")
}

@Test func aRereadKeepsWhatWasTypedAndShowsTheRestAsTheFilesHoldIt() throws {
    var model = TagEditorModel(tracks: [
        track("A", album: "Old", number: 1), track("B", album: "Old", number: 2),
    ])
    model.set(.title, "Typed")
    model.removeArt()
    model.reread([track("A", album: "New", number: 1), track("B", album: "New", number: 2)])
    #expect(model.text(.title) == "Typed")
    #expect(model.text(.album) == "New")
    #expect(model.art == .removed)
    #expect(try model.edit() == TagEdit(values: [.title: "Typed"], art: .remove))
}

@Test func aStoppedReadStartsNoMoreFiles() {
    let paths = (0..<(filesReadAtOnce * 4)).map { "\($0)" }
    let started = Started()
    let (tracks, problems) = readEditableTracks(
        paths, isStopped: { started.count >= 1 },
        read: { path in
            started.add()
            return track(path, album: nil, number: nil)
        })
    #expect(started.count < paths.count)
    #expect(tracks.count == started.count)
    #expect(problems.isEmpty)
}

private final class Started: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    func add() { lock.withLock { started += 1 } }
    var count: Int { lock.withLock { started } }
}
