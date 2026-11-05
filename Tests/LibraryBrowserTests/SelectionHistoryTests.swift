import Foundation
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

private func place(
    _ selection: Set<Int64>, in source: BrowserSource? = nil, search: String = "",
    top: Int64? = nil
) -> WindowPlace {
    WindowPlace(
        filter: TrackFilter(source: source, search: search), selection: selection,
        scroll: top.map { WindowPlace.Scroll(id: $0, offset: 0) })
}

@Test func undoAndRedoStepThroughTheSelections() {
    var history = SelectionHistory()
    #expect(!history.canUndo(from: place([])))
    history.record(place([1]), cause: .jump)
    history.record(place([2], in: .playlist(7)), cause: .jump)
    history.record(place([3], in: .playlist(7)), cause: .jump)
    #expect(history.undo(from: place([3], in: .playlist(7))) == place([2], in: .playlist(7)))
    #expect(history.undo(from: place([2], in: .playlist(7))) == place([1]))
    #expect(history.undo(from: place([1])) == nil)
    #expect(history.redo(from: place([1])) == place([2], in: .playlist(7)))
    // A new selection after undo drops the steps redo would have gone to.
    history.record(place([4], in: .playlist(7)), cause: .jump)
    #expect(!history.canRedo)
    #expect(history.steps.map(\.selection) == [[1], [2], [4]])
}

@Test func anEmptyOrUnchangedSelectionAddsNothing() {
    var history = SelectionHistory()
    history.record(place([1]), cause: .jump)
    history.record(place([]), cause: .jump)
    // The same tracks under a search stay the step they were.
    history.record(place([1], search: "a"), cause: .jump)
    #expect(history.steps == [place([1])])
    // In another source they're a step of their own.
    history.record(place([1], in: .history), cause: .jump)
    #expect(history.steps.count == 2)
}

@Test func movesByKeyInOneSourceAreOneStep() {
    var history = SelectionHistory()
    history.record(place([1]), cause: .jump)
    history.record(place([2]), cause: .key)
    history.record(place([2, 3]), cause: .key)
    history.record(place([2, 3, 4]), cause: .key)
    #expect(history.steps == [place([1]), place([2, 3, 4])])
    // A click ends the run, and a move after it starts another.
    history.record(place([9]), cause: .jump)
    history.record(place([10]), cause: .key)
    history.record(place([11]), cause: .key)
    #expect(history.steps.map(\.selection) == [[1], [2, 3, 4], [9], [11]])
    // Undo ends it too.
    _ = history.undo(from: place([11]))
    _ = history.redo(from: place([9]))
    history.record(place([12]), cause: .key)
    #expect(history.steps.map(\.selection) == [[1], [2, 3, 4], [9], [11], [12]])
}

@Test func aReloadsSelectionGivesWayToTheNextChange() {
    var history = SelectionHistory()
    history.record(place([1]), cause: .jump)
    history.record(place([1], in: .playlist(7)), cause: .reload)
    history.record(place([5], in: .playlist(7)), cause: .jump)
    #expect(history.steps == [place([1]), place([5], in: .playlist(7))])
}

@Test func undoFirstReturnsToTheStepTheWindowMovedOffAndRedoToWhereItWasLeft() {
    var history = SelectionHistory()
    history.record(place([1]), cause: .jump)
    history.record(place([2], top: 10), cause: .jump)
    // Another source shown, with nothing selected in it.
    #expect(history.canUndo(from: place([], in: .history)))
    #expect(history.undo(from: place([], in: .history)) == place([2], top: 10))
    // Scrolled since: redo comes back to where it was left.
    #expect(history.undo(from: place([2], top: 30)) == place([1], top: 10))
    #expect(history.redo(from: place([1], top: 10)) == place([2], top: 30))
}

@Test func theOldestStepsGoPastTheLimit() {
    var history = SelectionHistory()
    for id in 0..<Int64(SelectionHistory.limit + 5) { history.record(place([id]), cause: .jump) }
    #expect(history.steps.count == SelectionHistory.limit)
    #expect(history.steps.first == place([5]))
    #expect(history.position == SelectionHistory.limit - 1)
}

@Test func forgettingASourceDropsItsStepsAndTheRepeatsLeft() {
    var history = SelectionHistory()
    history.record(place([1]), cause: .jump)
    history.record(place([2], in: .playlist(7)), cause: .jump)
    history.record(place([1]), cause: .jump)
    history.record(place([3], in: .playlist(8)), cause: .jump)
    _ = history.undo(from: place([3], in: .playlist(8)))
    history.remove { $0 == .playlist(7) }
    #expect(history.steps == [place([1]), place([3], in: .playlist(8))])
    #expect(history.position == 0)
    history.remove { _ in true }
    #expect(history.position == nil)
    #expect(!history.canUndo(from: place([1])))
}
