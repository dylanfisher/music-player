import AppKit
import Foundation
import Testing

@testable import Metadata
@testable import TagEditor
@testable import TagWriter

/// Holds a background call until the test lets it go.
private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func open() { semaphore.signal() }
}

/// What the fakes saw, from any thread.
private final class Seen: @unchecked Sendable {
    // Every field is guarded by `lock`.
    private let lock = NSLock()
    private var _presented: [[String]] = []
    private var _alerts: [String] = []
    private var _confirmations: [String] = []
    private var _written: [[String]] = []
    private var _work: [String] = []
    private var _reads: [[String]] = []
    private var _places: [NSPoint?] = []

    var presented: [[String]] { lock.withLock { _presented } }
    var alerts: [String] { lock.withLock { _alerts } }
    var confirmations: [String] { lock.withLock { _confirmations } }
    var written: [[String]] { lock.withLock { _written } }
    /// The writes and undos, in the order they ran.
    var work: [String] { lock.withLock { _work } }
    var reads: [[String]] { lock.withLock { _reads } }
    /// Where each window was asked to open.
    var places: [NSPoint?] { lock.withLock { _places } }

    func present(_ paths: [String], at place: NSPoint?) {
        lock.withLock {
            _presented.append(paths)
            _places.append(place)
        }
    }
    func alert(_ message: String) { lock.withLock { _alerts.append(message) } }
    func confirm(_ message: String) { lock.withLock { _confirmations.append(message) } }
    func wrote(_ paths: [String]) { lock.withLock { _written.append(paths) } }
    func ran(_ work: String) { lock.withLock { _work.append(work) } }
    func read(_ paths: [String]) { lock.withLock { _reads.append(paths) } }
}

private func editable(_ path: String, title: String? = nil) -> EditableTrack {
    var tags = TrackTags()
    tags.title = title
    return EditableTrack(path: path, tags: tags, art: nil)
}

private typealias Read =
    @Sendable ([String], @escaping @Sendable () -> Bool) -> (
        [EditableTrack], [String]
    )

@MainActor
private func makeEditing(
    _ seen: Seen,
    read: @escaping Read = { paths, _ in (paths.map { editable($0) }, []) },
    write: @escaping @Sendable (TagEdit, [String]) -> TagWriteReport = { _, paths in
        var report = TagWriteReport()
        report.changed = paths
        return report
    },
    undo: @escaping @Sendable () -> TagWriteReport = { TagWriteReport() },
    confirm: Bool = true,
    progress: [TagWriteProgress] = []
) -> TagEditing {
    let editing = TagEditing(
        effects: .init(
            read: { paths, isStopped in
                seen.read(paths)
                let (tracks, problems) = read(paths, isStopped)
                return (tracks, problems)
            },
            write: { edit, paths, report in
                seen.ran("write \(paths.joined(separator: " "))")
                for step in progress { report(step) }
                return write(edit, paths)
            },
            undo: {
                seen.ran("undo")
                return undo()
            },
            present: { editor, _, place, _ in seen.present(editor.paths, at: place) },
            confirm: { message, _, answer in
                seen.confirm(message.message)
                answer(confirm)
            },
            alert: { message, _, _ in seen.alert(message) }))
    editing.written = { seen.wrote($0.changed) }
    return editing
}

/// Waits up to two seconds for `condition`, letting the main actor's tasks run.
@MainActor
private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(condition())
}

private let window = MainActor.assumeIsolated { NSWindow() }

@MainActor
private func editor(_ editing: TagEditing, _ paths: [String]) -> TagEditorWindow? {
    editing.editors.first { $0.paths == paths }
}

/// Get Info shows its window before the files are read, and opens and reads another window
/// while a write is still running.
@MainActor
@Test func getInfoOpensAtOnceWhileAWriteRuns() async throws {
    let seen = Seen()
    let gate = Gate()
    let editing = makeEditing(
        seen,
        write: { _, paths in
            gate.wait()
            var report = TagWriteReport()
            report.changed = paths
            return report
        })
    editing.open(["/a.flac"], over: window)
    #expect(seen.presented == [["/a.flac"]], "shown before its files are read")
    try await eventually { editor(editing, ["/a.flac"])?.isLoaded == true }
    editor(editing, ["/a.flac"])?.saved(TagEdit(values: [.title: "New"]))
    #expect(editing.isWriting)
    #expect(editor(editing, ["/a.flac"]) == nil, "the window closes once the write is queued")

    editing.open(["/b.flac"], over: window)
    #expect(seen.presented == [["/a.flac"], ["/b.flac"]])
    try await eventually { editor(editing, ["/b.flac"])?.isLoaded == true }
    #expect(editing.isWriting, "still writing /a.flac")
    gate.open()
    try await eventually { !editing.isWriting }
    #expect(seen.written == [["/a.flac"]])
}

/// Several windows open at once; Get Info on the tracks of an open one brings it forward.
@MainActor
@Test func severalInfoWindowsOpenAndTheSameTracksComeForward() async throws {
    let seen = Seen()
    let editing = makeEditing(seen)
    editing.open(["/a.flac"], over: window)
    editing.open(["/b.flac", "/c.flac"], over: window)
    try await eventually { editing.editors.allSatisfy(\.isLoaded) }
    #expect(editing.editors.map(\.paths) == [["/a.flac"], ["/b.flac", "/c.flac"]])
    editing.open(["/a.flac"], over: window)
    #expect(editing.editors.count == 2)
    #expect(seen.presented.last == ["/a.flac"])
    #expect(seen.reads.count == 2, "the open window isn't read again")
}

@MainActor
@Test func writesAndUndosRunOneAtATimeInTheOrderAsked() async throws {
    let seen = Seen()
    let gate = Gate()
    let editing = makeEditing(
        seen,
        write: { _, paths in
            if paths == ["/a.flac"] { gate.wait() }
            var report = TagWriteReport()
            report.changed = paths
            return report
        })
    editing.open(["/a.flac"], over: window)
    editing.open(["/b.flac"], over: window)
    try await eventually { editing.editors.allSatisfy(\.isLoaded) }
    editor(editing, ["/a.flac"])?.saved(TagEdit(values: [.title: "A"]))
    editor(editing, ["/b.flac"])?.saved(TagEdit(values: [.title: "B"]))
    editing.undo(over: window)
    #expect(editing.pendingWrites == 3)
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(seen.work == ["write /a.flac"])
    gate.open()
    try await eventually { !editing.isWriting }
    #expect(seen.work == ["write /a.flac", "write /b.flac", "undo"])
}

@MainActor
@Test func savingOneFileWritesItAndABatchAsksFirst() async throws {
    let seen = Seen()
    let editing = makeEditing(seen)
    editing.open(["/a.flac"], over: window)
    try await eventually { editor(editing, ["/a.flac"])?.isLoaded == true }
    editor(editing, ["/a.flac"])?.saved(TagEdit(values: [.title: "New"]))
    #expect(!editing.isOpen)
    try await eventually { seen.written == [["/a.flac"]] }
    #expect(seen.confirmations.isEmpty)

    let declining = makeEditing(seen, confirm: false)
    declining.open(["/a.flac", "/b.flac"], over: window)
    try await eventually { declining.editors.first?.isLoaded == true }
    declining.editors.first?.saved(TagEdit(values: [.album: "Both"]))
    #expect(seen.confirmations == ["Change the tags of 2 files?"])
    #expect(declining.isOpen, "declined, so the window stays open with what was typed")
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(seen.written == [["/a.flac"]], "declined, so nothing more was written")
}

/// Closing a window that's still reading stops its read and drops what it read.
@MainActor
@Test func closingAWindowThatIsReadingStopsTheRead() async throws {
    let seen = Seen()
    let stopped = Titles()
    let editing = makeEditing(
        seen,
        read: { paths, isStopped in
            let deadline = Date().addingTimeInterval(2)
            while !isStopped(), Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            if isStopped() { stopped.set("stopped", of: "read") }
            return (paths.map { editable($0) }, [])
        })
    editing.open(["/a.flac"], over: window)
    let opened = try #require(editor(editing, ["/a.flac"]))
    opened.close()
    #expect(!editing.isOpen)
    try await eventually { stopped.title(of: "read") == "stopped" }
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(!opened.isLoaded)
    #expect(seen.alerts.isEmpty)
}

/// A write to a file an open window shows reads that window's files again.
@MainActor
@Test func aWriteReadsAnOpenWindowOnItsFilesAgain() async throws {
    let seen = Seen()
    let titles = Titles()
    let editing = makeEditing(
        seen,
        read: { paths, _ in (paths.map { editable($0, title: titles.title(of: $0)) }, []) },
        write: { edit, paths in
            for path in paths { titles.set(edit.values[.title] ?? "", of: path) }
            var report = TagWriteReport()
            report.changed = paths
            return report
        })
    editing.open(["/a.flac", "/b.flac"], over: window)
    editing.open(["/a.flac"], over: window)
    editing.open(["/c.flac"], over: window)
    try await eventually { editing.editors.allSatisfy(\.isLoaded) }
    editor(editing, ["/a.flac"])?.saved(TagEdit(values: [.title: "New"]))
    let both = try #require(editor(editing, ["/a.flac", "/b.flac"]))
    try await eventually { both.model?.tracks.first?.tags.title == "New" }
    #expect(seen.reads.filter { $0 == ["/a.flac", "/b.flac"] }.count == 2)
    #expect(seen.reads.filter { $0 == ["/c.flac"] }.count == 1, "another file's window isn't")
}

private final class Titles: @unchecked Sendable {
    private let lock = NSLock()
    private var titles: [String: String] = [:]
    func title(of path: String) -> String? { lock.withLock { titles[path] } }
    func set(_ title: String, of path: String) { lock.withLock { titles[path] = title } }
}

@MainActor
@Test func undoFailuresAndAStoppedBatchAreShown() async throws {
    let seen = Seen()
    let editing = makeEditing(
        seen,
        undo: {
            var report = TagWriteReport()
            report.failures = [
                TagWriteError(path: "/a.flac", kind: .changedSinceEdit, detail: "changed")
            ]
            report.notWritten = ["/b.flac"]
            return report
        })
    editing.undo(over: window)
    try await eventually { !editing.isWriting }
    #expect(seen.alerts == ["Couldn't undo the tag edit for 1 file"])
    #expect(seen.written.isEmpty)
}

@MainActor
@Test func filesThatCantBeReadAreReportedAndTheWindowShowsTheRest() async throws {
    let seen = Seen()
    let editing = makeEditing(seen) { _, _ in ([editable("/a.flac")], ["/b.flac: unreadable"]) }
    editing.open(["/a.flac", "/b.flac"], over: window)
    try await eventually { editing.editors.first?.isLoaded == true }
    #expect(seen.alerts == ["1 of 2 files can't be read"])
    #expect(editing.editors.first?.model?.tracks.map(\.path) == ["/a.flac"])

    let none = makeEditing(seen) { _, _ in ([], ["/c.flac: unreadable"]) }
    none.open(["/c.flac"], over: window)
    try await eventually { seen.alerts.count == 2 }
    #expect(seen.alerts.last == "1 of 1 files can't be read")
    #expect(!none.isOpen, "nothing to edit, so the window closes")
}

/// A window opens where the user last moved one, and a move is passed on to be saved.
@MainActor
@Test func aWindowOpensWhereTheLastOneWasMoved() throws {
    let seen = Seen()
    let editing = makeEditing(seen)
    var saved: [NSPoint] = []
    editing.placeChanged = { saved.append($0) }
    editing.open(["/a.flac"], over: window)
    #expect(seen.places == [nil], "nothing saved yet")
    let moved = NSPoint(x: 300, y: 700)
    try #require(editor(editing, ["/a.flac"])).moved(moved)
    #expect(editing.place == moved)
    #expect(saved == [moved])
    editing.open(["/b.flac"], over: window)
    #expect(seen.places == [nil, moved])
}

/// A save tells the status bar how far it's got, file by file, and that it's done (ADR 0108).
@MainActor
@Test func aSaveShowsItsProgressThenClears() async throws {
    var step = TagWriteProgress(total: 2)
    var progress: [TagWriteProgress] = []
    for stage in [\TagWriteProgress.read, \.read, \.written, \.written] {
        step[keyPath: stage] += 1
        progress.append(step)
    }
    let editing = makeEditing(Seen(), progress: progress)
    var shown: [String?] = []
    var fractions: [Double] = []
    editing.saving = { status in
        shown.append(status?.text)
        if let status { fractions.append(status.fraction) }
    }
    editing.open(["/a.flac", "/b.flac"], over: window)
    try await eventually { editor(editing, ["/a.flac", "/b.flac"])?.isLoaded == true }
    editor(editing, ["/a.flac", "/b.flac"])?.saved(TagEdit(values: [.title: "New"]))
    try await eventually { !editing.isWriting }
    #expect(
        shown == [
            "Saving tags: 0 of 2", "Saving tags: 0 of 2", "Saving tags: 1 of 2",
            "Saving tags: 2 of 2", nil,
        ])
    #expect(fractions == [0.25, 0.5, 0.75, 1])
}

/// Back and Forward step the key info window's tabs, wrapping at the ends, and leave anything
/// else to the main window.
@MainActor
@Test func backAndForwardStepTheKeyInfoWindowsTabs() async throws {
    let editing = makeEditing(Seen())
    editing.open(["/a.flac"], over: window)
    editing.open(["/b.flac"], over: window)
    let first = try #require(editor(editing, ["/a.flac"]))
    let second = try #require(editor(editing, ["/b.flac"]))
    first.stepTab(-TagEditorTab.allCases.firstIndex(of: first.shownTab ?? .info)!)
    #expect(first.shownTab == .info)
    let secondTab = second.shownTab

    #expect(editing.hasTabs(first.window))
    #expect(editing.stepTab(-1, in: first.window))
    #expect(first.shownTab == TagEditorTab.allCases.last, "Back from the first tab wraps")
    #expect(editing.stepTab(1, in: first.window))
    #expect(first.shownTab == .info, "Forward from the last tab wraps")
    #expect(editing.stepTab(1, in: first.window))
    #expect(first.shownTab == .sorting)
    #expect(second.shownTab == secondTab, "only the key window's tabs move")

    #expect(!editing.hasTabs(window))
    #expect(!editing.stepTab(1, in: window), "the main window goes forward instead")
    #expect(!editing.stepTab(1, in: nil))
    // The next window opens on the tab last shown; the other tests expect the first.
    first.stepTab(-1)
}

/// Get Info on a DSF, a DSDIFF and a FLAC shows all three; Save writes only the FLAC, at once
/// as one file, and the DSD files are left as they were.
@MainActor
@Test func saveWritesOnlyTheFilesWhoseTagsCanBeWritten() async throws {
    let seen = Seen()
    let dsd = try ["dsf", "dff"].map { try dsdFixture($0) }
    let before = try dsd.map { try Data(contentsOf: $0) }
    let paths = dsd.map(\.path) + ["/a.flac"]
    let editing = makeEditing(
        seen,
        read: { paths, isStopped in
            readEditableTracks(paths, isStopped: isStopped) { path in
                path.hasSuffix(".flac") ? editable(path) : try readEditableTrack(path)
            }
        })
    editing.open(paths, over: window)
    try await eventually { editor(editing, paths)?.isLoaded == true }
    #expect(seen.alerts.isEmpty, "every file was read")
    #expect(editor(editing, paths)?.model?.tracks.count == 3)
    editor(editing, paths)?.saved(TagEdit(values: [.title: "New"]))
    try await eventually { seen.written == [["/a.flac"]] }
    #expect(seen.work == ["write /a.flac"])
    #expect(seen.confirmations.isEmpty, "one file is written, so nothing asks")
    #expect(try dsd.map { try Data(contentsOf: $0) } == before)
}
