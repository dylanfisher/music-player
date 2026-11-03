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

/// What the fakes saw, on the main actor.
@MainActor
private final class Seen {
    var presented: [[String]] = []
    var alerts: [String] = []
    var confirmations: [String] = []
    var written: [[String]] = []
}

private func editable(_ path: String) -> EditableTrack {
    EditableTrack(path: path, tags: TrackTags(), art: nil)
}

@MainActor
private func makeEditing(
    _ seen: Seen,
    read: @escaping @Sendable ([String]) -> ([EditableTrack], [String]) = {
        ($0.map(editable), [])
    },
    write: @escaping @Sendable (TagEdit, [String]) -> TagWriteReport = { _, paths in
        var report = TagWriteReport()
        report.changed = paths
        return report
    },
    undo: @escaping @Sendable () -> TagWriteReport = { TagWriteReport() },
    confirm: Bool = true
) -> TagEditing {
    let editing = TagEditing(
        effects: .init(
            read: {
                let (tracks, problems) = read($0)
                return (tracks, problems)
            },
            write: write, undo: undo,
            present: { sheet, _ in seen.presented.append(sheet.model.tracks.map(\.path)) },
            confirm: { message, _, answer in
                seen.confirmations.append(message.message)
                answer(confirm)
            },
            alert: { message, _, _ in seen.alerts.append(message) }))
    editing.written = { seen.written.append($0) }
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
@Test func aSlowReadForAnEarlierOpenIsDropped() async throws {
    let seen = Seen()
    let gate = Gate()
    let editing = makeEditing(seen) { paths in
        if paths == ["/a.flac"] { gate.wait() }
        return (paths.map(editable), [])
    }
    editing.open(["/a.flac"], over: window)
    try await Task.sleep(nanoseconds: 50_000_000)
    editing.open(["/b.flac"], over: window)
    try await eventually { seen.presented == [["/b.flac"]] }
    gate.open()
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(seen.presented == [["/b.flac"]])
    #expect(editing.isOpen)
}

@MainActor
@Test func savingOneFileWritesItAndABatchAsksFirst() async throws {
    let seen = Seen()
    let editing = makeEditing(seen)
    editing.open(["/a.flac"], over: window)
    try await eventually { editing.isOpen }
    editing.sheet?.saved(TagEdit(values: [.title: "New"]))
    #expect(!editing.isOpen)
    try await eventually { seen.written == [["/a.flac"]] }
    #expect(seen.confirmations.isEmpty)

    let declining = makeEditing(seen, confirm: false)
    declining.open(["/a.flac", "/b.flac"], over: window)
    try await eventually { declining.isOpen }
    declining.sheet?.saved(TagEdit(values: [.album: "Both"]))
    #expect(seen.confirmations == ["Change the tags of 2 files?"])
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(seen.written == [["/a.flac"]], "declined, so nothing more was written")
}

@MainActor
@Test func theEditorOpensAgainAfterItIsCancelled() async throws {
    let seen = Seen()
    let editing = makeEditing(seen)
    editing.open(["/a.flac"], over: window)
    try await eventually { editing.isOpen }
    editing.sheet?.cancel()
    #expect(!editing.isOpen)
    editing.open(["/b.flac"], over: window)
    try await eventually { seen.presented == [["/a.flac"], ["/b.flac"]] }
}

@MainActor
@Test func nothingOpensOrUndoesWhileAWriteRuns() async throws {
    let seen = Seen()
    let gate = Gate()
    let editing = makeEditing(
        seen,
        undo: {
            gate.wait()
            var report = TagWriteReport()
            report.changed = ["/a.flac"]
            return report
        })
    editing.undo(over: window)
    #expect(editing.isBusy)
    editing.open(["/b.flac"], over: window)
    editing.undo(over: window)
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(seen.presented.isEmpty)
    gate.open()
    try await eventually { !editing.isBusy }
    #expect(seen.written == [["/a.flac"]], "one undo ran")
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
    try await eventually { !editing.isBusy }
    #expect(seen.alerts == ["Couldn't undo the tag edit for 1 file"])
    #expect(seen.written.isEmpty)
}

@MainActor
@Test func filesThatCantBeReadAreReportedAndTheEditorOpensOnTheRest() async throws {
    let seen = Seen()
    let editing = makeEditing(seen) { _ in ([editable("/a.flac")], ["/b.flac: unreadable"]) }
    editing.open(["/a.flac", "/b.flac"], over: window)
    try await eventually { editing.isOpen }
    #expect(seen.alerts == ["1 of 2 files can't be edited"])
    #expect(seen.presented == [["/a.flac"]])
}

@MainActor
@Test func getInfoOnMoreFilesThanTheThresholdAsksBeforeReading() async throws {
    let seen = Seen()
    let reads = Counter()
    let editing = makeEditing(
        seen,
        read: { paths in
            reads.add()
            return (paths.map(editable), [])
        }, confirm: false)
    let atThreshold = (0..<TagEditing.confirmReadAbove).map { "/\($0).flac" }
    editing.open(atThreshold, over: window)
    try await eventually { seen.presented.count == 1 }
    #expect(seen.confirmations.isEmpty)

    editing.sheet?.cancelled()
    let over = atThreshold + ["/over.flac"]
    editing.open(over, over: window)
    #expect(seen.confirmations == ["Read the tags of \(over.count) files?"])
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(reads.value == 1)
    #expect(seen.presented.count == 1)

    let agreeing = makeEditing(
        seen,
        read: { paths in
            reads.add()
            return (paths.map(editable), [])
        })
    agreeing.open(over, over: window)
    try await eventually { seen.presented.count == 2 }
    #expect(reads.value == 2)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
