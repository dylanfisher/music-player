import AppKit
import Foundation
import Testing

@testable import Commands
@testable import Fixtures
@testable import Library
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
    private var _cascades: [String?] = []
    private var _edits: [[TagEdit]] = []
    private var _origins: [TagEditOrigin] = []

    var presented: [[String]] { lock.withLock { _presented } }
    var alerts: [String] { lock.withLock { _alerts } }
    var confirmations: [String] { lock.withLock { _confirmations } }
    var written: [[String]] { lock.withLock { _written } }
    /// The writes and undos, in the order they ran.
    var work: [String] { lock.withLock { _work } }
    var reads: [[String]] { lock.withLock { _reads } }
    /// The title of the window each one was asked to cascade from, nil for none.
    var cascades: [String?] { lock.withLock { _cascades } }
    /// Each write's edits, a file's each.
    var edits: [[TagEdit]] { lock.withLock { _edits } }
    /// Each write's origin.
    var origins: [TagEditOrigin] { lock.withLock { _origins } }

    func present(_ paths: [String], after last: String?) {
        lock.withLock {
            _presented.append(paths)
            _cascades.append(last)
        }
    }
    func alert(_ message: String) { lock.withLock { _alerts.append(message) } }
    func confirm(_ message: String) { lock.withLock { _confirmations.append(message) } }
    func wrote(_ paths: [String]) { lock.withLock { _written.append(paths) } }
    func ran(_ work: String) { lock.withLock { _work.append(work) } }
    func read(_ paths: [String]) { lock.withLock { _reads.append(paths) } }
    func edited(_ edits: [TagEdit]) { lock.withLock { _edits.append(edits) } }
    func came(from origin: TagEditOrigin) { lock.withLock { _origins.append(origin) } }
}

private func editable(_ path: String, title: String? = nil) -> EditableTrack {
    var tags = TrackTags()
    tags.title = title
    return EditableTrack(path: path, tags: tags, pictures: [])
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
    newestEdit: @escaping @Sendable () throws(TagWriteError) -> JournaledEdit? = { nil },
    confirm: Bool = true,
    progress: [TagWriteProgress] = [],
    organize: @escaping @Sendable ([String], String) -> FilesOrganized = { _, _ in
        FilesOrganized()
    },
    askQuit:
        @escaping @MainActor (Int, @escaping @MainActor (TagEditing.QuitAnswer) -> Void) ->
        Void = { _, _ in Issue.record("asked to quit") }
) -> TagEditing {
    let editing = TagEditing(
        effects: .init(
            read: { paths, isStopped in
                seen.read(paths)
                let (tracks, problems) = read(paths, isStopped)
                return (tracks, problems)
            },
            write: { files, origin, report in
                let paths = files.map(\.path)
                seen.ran("write \(paths.joined(separator: " "))")
                seen.came(from: origin)
                for step in progress { report(step) }
                seen.edited(files.map(\.edit))
                return write(files[0].edit, paths)
            },
            undo: { expected in
                seen.ran(expected.map { "undo \($0.sequence)" } ?? "undo")
                return undo()
            },
            newestEdit: newestEdit,
            present: { editor, last in seen.present(editor.paths, after: last?.title) },
            confirm: { message, _, answer in
                seen.confirm(message.message)
                answer(confirm)
            },
            alert: { message, _, _ in seen.alert(message) },
            layout: { paths, folder in
                seen.ran("layout \(paths.joined(separator: " ")) in \(folder)")
                return organize(paths, folder)
            },
            move: { plan, folder, checkingAgain in
                seen.ran(
                    "move \(plan.moved.map(\.from).joined(separator: " ")) in \(folder)"
                        + (checkingAgain ? ", checking again" : ""))
                return plan
            },
            follow: { moves in
                seen.ran("follow \(moves.map { "\($0.from)>\($0.to)" }.joined(separator: " "))")
                return []
            }, askQuit: askQuit))
    editing.written = { report, _ in seen.wrote(report.changed) }
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
    editing.undo(over: window, from: .tagEditor)
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
    editing.undo(over: window, from: .tagEditor)
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

/// A window opened while another is open cascades from the last one open; with none open it
/// opens at the frame the info windows keep.
@MainActor
@Test func aWindowCascadesFromTheLastOneOpen() throws {
    let seen = Seen()
    let editing = makeEditing(seen)
    editing.open(["/a.flac"], over: window)
    #expect(seen.cascades == [nil])
    try #require(editor(editing, ["/a.flac"])).window.orderFront(nil)
    editing.open(["/b.flac"], over: window)
    #expect(seen.cascades.last == "a.flac")
    for editor in editing.editors { editor.close() }
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

/// The Discogs tagger's write tells its caller how far it's got, as it tells the status bar,
/// so the tagger's window can show it too.
@MainActor
@Test func aTaggerWriteTellsItsCallerItsProgress() async throws {
    var step = TagWriteProgress(total: 1)
    var progress: [TagWriteProgress] = []
    for stage in [\TagWriteProgress.read, \.written] {
        step[keyPath: stage] += 1
        progress.append(step)
    }
    let editing = makeEditing(Seen(), progress: progress)
    var heard: [TagWriteProgress] = []
    var unwritten: Set<String>?
    editing.write(
        [("/b.flac", TagEdit(values: [.title: "New"]))], over: window,
        progress: { heard.append($0) }, completion: { unwritten = $0 })
    try await eventually { unwritten != nil }
    #expect(heard == progress)
}

/// The status bar counts every batch queued since the queue was last empty, so a batch queued
/// mid-write raises the total at once and a finished batch stays counted until the queue
/// drains: the count never goes backwards.
@MainActor
@Test func theSavingStatusCountsEveryQueuedBatch() async throws {
    var step = TagWriteProgress(total: 1)
    var progress: [TagWriteProgress] = []
    for stage in [\TagWriteProgress.read, \.written] {
        step[keyPath: stage] += 1
        progress.append(step)
    }
    let gate = Gate()
    let editing = makeEditing(
        Seen(),
        write: { _, paths in
            if paths == ["/a.flac"] { gate.wait() }
            var report = TagWriteReport()
            report.changed = paths
            return report
        }, progress: progress)
    var shown: [String?] = []
    editing.saving = { shown.append($0?.text) }
    let edit = TagEdit(values: [.title: "New"])
    editing.write([("/a.flac", edit)], over: window)
    try await eventually { shown.last == "Saving tags: 1 of 1" }
    editing.write([("/b.flac", edit), ("/c.flac", edit)], over: window)
    #expect(shown.last == "Saving tags: 1 of 3")
    gate.open()
    try await eventually { !editing.isWriting }
    #expect(
        shown == [
            "Saving tags: 0 of 1", "Saving tags: 1 of 1", "Saving tags: 1 of 3",
            "Saving tags: 1 of 3", "Saving tags: 2 of 3", nil,
        ])
}

/// Quitting with nothing queued goes ahead unasked; with writes queued it asks, and each
/// answer quits or not as it says. Wait and Quit waits for the writes queued meanwhile too
/// (ADR 0167).
@MainActor
@Test func quittingWithWritesQueuedAsksFirst() async throws {
    let idle = makeEditing(Seen())
    #expect(!idle.holdQuit { _ in Issue.record("quit answered") })

    let edit = TagEdit(values: [.title: "New"])
    for (answer, quits) in [(TagEditing.QuitAnswer.cancel, false), (.quitAnyway, true)] {
        let gate = Gate()
        var asked: [Int] = []
        let editing = makeEditing(
            Seen(),
            write: { _, paths in
                gate.wait()
                var report = TagWriteReport()
                report.changed = paths
                return report
            },
            askQuit: { count, reply in
                asked.append(count)
                reply(answer)
            })
        editing.write([("/a.flac", edit)], over: window)
        editing.write([("/b.flac", edit)], over: window)
        var quit: Bool?
        #expect(editing.holdQuit { quit = $0 })
        #expect(quit == nil, "it answers after returning")
        try await eventually { quit != nil }
        #expect(quit == quits)
        #expect(asked == [2])
        #expect(editing.isWriting)
        gate.open()
        gate.open()
        try await eventually { !editing.isWriting }
    }

    let gate = Gate()
    let editing = makeEditing(
        Seen(),
        write: { _, paths in
            gate.wait()
            var report = TagWriteReport()
            report.changed = paths
            return report
        },
        askQuit: { _, reply in reply(.waitAndQuit) })
    var unwritten: [Set<String>] = []
    editing.write([("/a.flac", edit)], over: window, completion: { unwritten.append($0) })
    var quit: Bool?
    #expect(editing.holdQuit { quit = $0 })
    try await Task.sleep(nanoseconds: 50_000_000)
    editing.write([("/b.flac", edit)], over: window, completion: { unwritten.append($0) })
    gate.open()
    try await eventually { unwritten.count == 1 }
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(quit == nil, "a write queued while waiting is waited for")
    gate.open()
    try await eventually { quit != nil }
    #expect(quit == true)
    #expect(unwritten.count == 2)
    #expect(!editing.isWriting)
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

/// With a sheet on an info window, Back and Forward are taken and move nothing: not the tabs
/// behind the sheet, and not the main window.
@MainActor
@Test func backAndForwardDoNothingWhileASheetIsOnAnInfoWindow() async throws {
    let editing = makeEditing(Seen())
    editing.open(["/a.flac"], over: window)
    let info = try #require(editor(editing, ["/a.flac"]))
    info.window.orderFront(nil)
    defer { info.close() }
    let sheet = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
        backing: .buffered, defer: false)
    info.window.beginSheet(sheet, completionHandler: nil)
    defer { info.window.endSheet(sheet) }
    try await eventually { sheet.sheetParent === info.window }
    let tab = info.shownTab

    #expect(editing.stepTab(1, in: sheet), "the browser doesn't go forward")
    #expect(editing.stepTab(-1, in: sheet), "the browser doesn't go back")
    #expect(info.shownTab == tab)
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

/// The Discogs tagger's Apply hands each file its own edit: one write, queued after the
/// others, asking nothing more, with a save's progress (ADR 0133).
@MainActor
@Test func aBatchOfEditsPerFileIsOneWriteAfterThoseQueued() async throws {
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
    var shown: [String?] = []
    editing.saving = { shown.append($0?.text) }
    editing.open(["/a.flac"], over: window)
    try await eventually { editor(editing, ["/a.flac"])?.isLoaded == true }
    editor(editing, ["/a.flac"])?.saved(TagEdit(values: [.title: "New"]))
    let edits = [TagEdit(values: [.title: "One"]), TagEdit(values: [.title: "Two"])]
    editing.write([("/b.flac", edits[0]), ("/c.flac", edits[1])], over: window)
    editing.write([], over: window)
    gate.open()
    try await eventually { !editing.isWriting }
    #expect(seen.work == ["write /a.flac", "write /b.flac /c.flac"])
    #expect(seen.origins == [.tagEditor, .discogsTagger])
    #expect(seen.edits.last == edits)
    #expect(seen.confirmations.isEmpty)
    #expect(seen.written == [["/a.flac"], ["/b.flac", "/c.flac"]])
    #expect(shown.last == .some(nil))
}

/// Undo Tag Edit undoes the newest edit anywhere, so it asks first when another kind of
/// window made it; Cancel leaves the edit undoable. The undo is handed the edit it asked about,
/// so it undoes that one or none (ADR 0136).
@MainActor
@Test func undoAsksBeforeUndoingAnotherWindowsEdit() async throws {
    let edit = { (origin: TagEditOrigin?, count: Int) in
        JournaledEdit(sequence: 7, origin: origin, fileCount: count)
    }
    for (answer, ran) in [(false, [String]()), (true, ["undo 7"])] {
        let seen = Seen()
        let newest = edit(.discogsTagger, 22)
        let editing = makeEditing(seen, newestEdit: { newest }, confirm: answer)
        editing.undo(over: window, from: .tagEditor)
        try await eventually { !editing.isWriting && !seen.confirmations.isEmpty }
        #expect(seen.confirmations == ["Undo the Discogs tagger's edit of 22 files?"])
        #expect(seen.work == ran)
    }
    #expect(
        TagEditing.Confirmation.undoing(.tagEditor, 1).message
            == "Undo an info window's edit of 1 file?")

    // The same window's edit, one whose window isn't known, and none, ask nothing.
    for (newest, origin, ran) in [
        (edit(.discogsTagger, 3), TagEditOrigin.discogsTagger, "undo 7"),
        (edit(nil, 3), .tagEditor, "undo 7"), (nil, .tagEditor, "undo"),
    ] {
        let seen = Seen()
        let editing = makeEditing(seen, newestEdit: { newest })
        editing.undo(over: window, from: origin)
        try await eventually { seen.work == [ran] }
        #expect(seen.confirmations.isEmpty)
    }
}

/// A journal of edits the fakes write and undo, from any thread, which can fail to be read.
private final class FakeJournal: @unchecked Sendable {
    // Every field is guarded by `lock`.
    private let lock = NSLock()
    private var edits: [JournaledEdit] = []
    private var _unreadable = false

    var unreadable: Bool {
        get { lock.withLock { _unreadable } }
        set { lock.withLock { _unreadable = newValue } }
    }

    func add(_ fileCount: Int) {
        lock.withLock {
            edits.append(
                JournaledEdit(sequence: edits.count + 1, origin: .tagEditor, fileCount: fileCount))
        }
    }
    func undoNewest() { lock.withLock { _ = edits.popLast() } }
    func newest() throws(TagWriteError) -> JournaledEdit? {
        let (unreadable, newest) = lock.withLock { (_unreadable, edits.last) }
        guard !unreadable else {
            throw TagWriteError(path: "/journal", kind: .journal, detail: "unreadable")
        }
        return newest
    }
}

/// Undo Tag Edit is on only while the journal holds an edit: off with none, on after a write,
/// the Discogs tagger's too, off again once the only edit is undone. A journal that can't be
/// read leaves it on, so a click shows why. The info window's button follows.
@MainActor
@Test func undoTagEditIsOnOnlyWithAnEditToUndo() async throws {
    let seen = Seen()
    let journal = FakeJournal()
    let editing = makeEditing(
        seen,
        write: { _, paths in
            journal.add(paths.count)
            var report = TagWriteReport()
            report.changed = paths
            return report
        },
        undo: {
            journal.undoNewest()
            return TagWriteReport()
        },
        newestEdit: { () throws(TagWriteError) in try journal.newest() })
    editing.isEnabled = { [weak editing] in $0 == .undoTagEdit && editing?.canUndo == true }
    editing.open(["/a.flac"], over: window)
    let opened = try #require(editor(editing, ["/a.flac"]))
    let button = try #require(opened.commandButtons.first { $0.id == .undoTagEdit }?.button)
    try await eventually { !editing.canUndo }
    #expect(!button.isEnabled)

    editing.write([("/b.flac", TagEdit(values: [.title: "New"]))], over: window)
    try await eventually { editing.canUndo }
    #expect(button.isEnabled)

    editing.undo(over: window, from: .tagEditor)
    try await eventually { !editing.canUndo }
    #expect(seen.work == ["write /b.flac", "undo 1"])
    #expect(!button.isEnabled)

    journal.unreadable = true
    editing.write([("/b.flac", TagEdit(values: [.title: "Again"]))], over: window)
    try await eventually { editing.canUndo }
    #expect(button.isEnabled)
    opened.close()
}

/// An info window's Undo Tag Edit, Replace Artwork… and Remove Artwork buttons ask the
/// registry, as the menu items do, and run its commands.
@MainActor
@Test func theEditorsCommandButtonsFollowTheCommandsRules() async throws {
    let seen = Seen()
    let editing = makeEditing(
        seen,
        read: { paths, _ in
            (paths.map { EditableTrack(path: $0, tags: TrackTags(), pictures: frontCovers(Data([1, 2, 3]))) }, [])
        })
    // The registry's rule for Undo Tag Edit, with the main window open or closed; the art
    // commands' rules are the editor's own.
    var mainWindowOpen = true
    editing.isEnabled = { $0 == .undoTagEdit && mainWindowOpen }
    var ran: [CommandID] = []
    editing.run = { ran.append($0) }
    editing.open(["/a.flac"], over: window)
    let opened = try #require(editor(editing, ["/a.flac"]))
    // Every tab built, so each tab's buttons are there; a full turn ends on the tab it began.
    for _ in TagEditorTab.allCases { opened.stepTab(1) }
    func enabled(_ id: CommandID) -> [Bool] {
        opened.commandButtons.filter { $0.id == id }.map(\.button.isEnabled)
    }
    #expect(
        Set(opened.commandButtons.map(\.id)) == [.undoTagEdit, .replaceArtwork, .removeArtwork])
    #expect(enabled(.undoTagEdit) == [true])
    #expect(!enabled(.replaceArtwork).isEmpty && !enabled(.replaceArtwork).contains(true), "unread")
    try await eventually { opened.isLoaded }
    #expect(!enabled(.replaceArtwork).contains(false))
    #expect(!enabled(.removeArtwork).isEmpty && !enabled(.removeArtwork).contains(false))
    opened.removeArt()
    #expect(!enabled(.removeArtwork).contains(true), "nothing left to remove")
    #expect(!enabled(.replaceArtwork).contains(false))

    for (_, button) in opened.commandButtons where button.isEnabled { click(button) }
    #expect(Set(ran) == [.undoTagEdit, .replaceArtwork])
    mainWindowOpen = false
    editing.refreshCommands()
    #expect(enabled(.undoTagEdit) == [false])
    opened.close()
}

/// Each info window's art buttons follow its own files, not the key or last window's, and run
/// on their own window.
@MainActor
@Test func eachEditorsArtButtonsFollowItsOwnFiles() async throws {
    let seen = Seen()
    let editing = makeEditing(
        seen,
        read: { paths, _ in
            (
                paths.map {
                    EditableTrack(
                        path: $0, tags: TrackTags(), pictures: frontCovers($0 == "/art.flac" ? Data([1]) : nil))
                }, []
            )
        })
    var targets: [[String]] = []
    editing.run = { _ in targets.append(editing.active?.paths ?? []) }
    editing.open(["/bare.flac"], over: window)
    editing.open(["/art.flac"], over: window)
    let bare = try #require(editor(editing, ["/bare.flac"]))
    let art = try #require(editor(editing, ["/art.flac"]))
    try await eventually { bare.isLoaded && art.isLoaded }
    #expect(editing.active === art, "the art commands' window, for the menus")
    func enabled(_ editor: TagEditorWindow, _ id: CommandID) -> [Bool] {
        editor.commandButtons.filter { $0.id == id }.map(\.button.isEnabled)
    }
    #expect(!enabled(art, .removeArtwork).isEmpty && !enabled(art, .removeArtwork).contains(false))
    #expect(!enabled(bare, .removeArtwork).isEmpty && !enabled(bare, .removeArtwork).contains(true))
    #expect(!enabled(bare, .replaceArtwork).contains(false))
    let replace = try #require(bare.commandButtons.first { $0.id == .replaceArtwork }?.button)
    click(replace)
    #expect(targets == [["/bare.flac"]], "run on the window whose button it is")
    #expect(editing.active === art)
    bare.close()
    art.close()
}

/// The titles the fake files hold, which an undo changes, from any thread.
private final class FileTitles: @unchecked Sendable {
    // `title` is guarded by `lock`.
    private let lock = NSLock()
    private var title = "Edited"

    var current: String {
        get { lock.withLock { title } }
        set { lock.withLock { title = newValue } }
    }
}

/// Undo Tag Edit undoes the newest edit wherever it was made, says so, and reads again every
/// open window on the files it put back, keeping what was typed in them.
@MainActor
@Test func anUndoReadsAgainTheWindowsOnTheFilesItPutBack() async throws {
    let seen = Seen()
    let titles = FileTitles()
    let editing = makeEditing(
        seen,
        read: { paths, _ in
            (
                paths.map {
                    var tags = TrackTags()
                    tags.title = titles.current
                    tags.artist = "Artist"
                    return EditableTrack(path: $0, tags: tags, pictures: [])
                }, []
            )
        },
        undo: {
            titles.current = "Before"
            var report = TagWriteReport()
            report.changed = ["/a.flac"]
            return report
        })
    editing.open(["/a.flac"], over: window)
    editing.open(["/b.flac"], over: window)
    let touched = try #require(editor(editing, ["/a.flac"]))
    let other = try #require(editor(editing, ["/b.flac"]))
    try await eventually { touched.isLoaded && other.isLoaded }
    let undo = try #require(touched.commandButtons.first { $0.id == .undoTagEdit }?.button)
    #expect(undo.toolTip == "Undoes the last tag edit, wherever it was made")
    let artist = try #require(touched.fields[.artist]?.first)
    artist.stringValue = "Typed"
    touched.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: artist))
    let reads = seen.reads.count
    editing.undo(over: window, from: .tagEditor)
    try await eventually { touched.model?.text(.title) == "Before" }
    #expect(touched.model?.text(.artist) == "Typed", "what was typed stays")
    #expect(other.model?.text(.title) == "Edited", "a window on other files isn't read")
    #expect(seen.reads.count == reads + 1)
    touched.close()
    other.close()
}

/// Moves `/lib/a.flac` to `/lib/A/a.flac`, leaves the rest, and finds what isn't in `/lib`
/// outside.
private let organizeA: @Sendable ([String], String) -> FilesOrganized = { paths, _ in
    var result = FilesOrganized()
    result.moved = paths.filter { $0 == "/lib/a.flac" }.map {
        TrackMove(from: $0, to: "/lib/A/a.flac")
    }
    result.outside = paths.filter { !$0.hasPrefix("/lib/") }
    return result
}

/// With Keep Files Organized on, a write is followed on the write queue by the renames and
/// the journal's follow, before the undo queued after it, so the undo finds the file at its
/// new path; the rescan is told the new path (ADR 0164).
@MainActor
@Test func keepFilesOrganizedRenamesAfterAWriteAndBeforeTheNextUndo() async throws {
    let seen = Seen()
    let editing = makeEditing(seen, organize: organizeA)
    var organized: [FilesOrganized?] = []
    editing.written = { report, result in
        seen.wrote(report.changed)
        organized.append(result)
    }
    editing.organizingFolder = { "/lib" }
    editing.write(
        [
            ("/lib/a.flac", TagEdit(values: [.title: "A"])), ("/lib/b.flac", TagEdit()),
            ("/elsewhere/c.flac", TagEdit()),
        ], over: window)
    editing.undo(over: window, from: .discogsTagger)
    try await eventually { seen.work.count == 5 && !editing.isWriting }
    #expect(
        seen.work == [
            "write /lib/a.flac /lib/b.flac /elsewhere/c.flac",
            "layout /lib/a.flac /lib/b.flac /elsewhere/c.flac in /lib", "move /lib/a.flac in /lib",
            "follow /lib/a.flac>/lib/A/a.flac", "undo",
        ])
    #expect(seen.written.first == ["/lib/A/a.flac", "/lib/b.flac", "/elsewhere/c.flac"])
    #expect(organized.first??.moved == [TrackMove(from: "/lib/a.flac", to: "/lib/A/a.flac")])
    #expect(organized.first??.outside == [])
}

/// With the setting off, a write renames nothing.
@MainActor
@Test func aWriteWithKeepFilesOrganizedOffRenamesNothing() async throws {
    let seen = Seen()
    let editing = makeEditing(seen, organize: organizeA)
    editing.write([("/lib/a.flac", TagEdit(values: [.title: "A"]))], over: window)
    try await eventually { !editing.isWriting && !seen.written.isEmpty }
    #expect(seen.work == ["write /lib/a.flac"])
    #expect(seen.written == [["/lib/a.flac"]])
}

/// Organize Selected Files runs the plan the user confirmed, checking each file again, after
/// the writes queued before it, whatever the setting, and the rescan is told the moved files'
/// new paths.
@MainActor
@Test func organizeSelectedFilesRunsAfterTheQueuedWrites() async throws {
    let seen = Seen()
    let gate = Gate()
    let editing = makeEditing(
        seen,
        write: { _, paths in
            gate.wait()
            var report = TagWriteReport()
            report.changed = paths
            return report
        }, organize: organizeA)
    editing.write([("/lib/b.flac", TagEdit(values: [.title: "B"]))], over: window)
    let confirmed = organizeA(["/lib/a.flac", "/elsewhere/c.flac"], "/lib")
    editing.organize(confirmed, in: "/lib", over: window)
    #expect(seen.work.count <= 1)
    gate.open()
    try await eventually { !editing.isWriting && seen.written.count == 2 }
    #expect(
        seen.work == [
            "write /lib/b.flac", "move /lib/a.flac in /lib, checking again",
            "follow /lib/a.flac>/lib/A/a.flac",
        ])
    #expect(seen.written.last == ["/lib/A/a.flac"])
}
