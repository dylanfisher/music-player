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

/// Notes `place` and lets it settle, as five quiet seconds do.
private func record(_ history: inout SelectionHistory, _ place: WindowPlace) {
    history.note(place)
    history.settle()
}

@Test func undoAndRedoStepThroughTheSelections() {
    var history = SelectionHistory()
    #expect(!history.canUndo(from: place([])))
    record(&history, place([1]))
    record(&history, place([2], in: .playlist(7)))
    record(&history, place([3], in: .playlist(7)))
    #expect(history.undo(from: place([3], in: .playlist(7))) == place([2], in: .playlist(7)))
    #expect(history.undo(from: place([2], in: .playlist(7))) == place([1]))
    #expect(history.undo(from: place([1])) == nil)
    #expect(history.redo(from: place([1])) == place([2], in: .playlist(7)))
    // A new selection after undo drops the steps redo would have gone to.
    record(&history, place([4], in: .playlist(7)))
    #expect(!history.canRedo)
    #expect(history.steps.map(\.selection) == [[1], [2], [4]])
}

@Test func anEmptyOrUnchangedSelectionAddsNothing() {
    var history = SelectionHistory()
    record(&history, place([1]))
    record(&history, place([]))
    // The same tracks under a search stay the step they were.
    record(&history, place([1], search: "a"))
    #expect(history.steps == [place([1])])
    // In another source they're a step of their own.
    record(&history, place([1], in: .history))
    #expect(history.steps.count == 2)
}

@Test func selectionsBeforeTheyStayPutCollapseIntoTheLastOne() {
    var history = SelectionHistory()
    record(&history, place([1]))
    history.note(place([2]))
    history.note(place([2, 3]))
    history.note(place([2, 3, 4]))
    #expect(history.steps == [place([1])])
    history.settle()
    #expect(history.steps == [place([1]), place([2, 3, 4])])
    // Nothing pending, so settling again adds nothing.
    history.settle()
    #expect(history.steps.count == 2)
}

@Test func aSelectionBackOnTheCurrentStepAddsNothing() {
    var history = SelectionHistory()
    record(&history, place([1]))
    history.note(place([2]))
    history.note(place([1]))
    history.settle()
    #expect(history.steps == [place([1])])
}

@Test func anEmptySelectionLeavesNothingPending() {
    var history = SelectionHistory()
    record(&history, place([1]))
    history.note(place([2]))
    history.note(place([]))
    history.settle()
    #expect(history.steps == [place([1])])
}

@Test func undoSettlesThePendingSelectionSoRedoComesBackToIt() {
    var history = SelectionHistory()
    record(&history, place([1]))
    history.note(place([2]))
    #expect(history.canUndo(from: place([2])))
    #expect(!history.canRedo)
    #expect(history.undo(from: place([2])) == place([1]))
    #expect(history.redo(from: place([1])) == place([2]))
    #expect(history.steps.map(\.selection) == [[1], [2]])
}

@Test func aFirstPendingSelectionIsNothingToUndoTo() {
    var history = SelectionHistory()
    history.note(place([1]))
    #expect(!history.canUndo(from: place([1])))
    #expect(history.undo(from: place([1])) == nil)
    #expect(history.steps == [place([1])])
}

@Test func forgettingASourceDropsItsPendingSelection() {
    var history = SelectionHistory()
    record(&history, place([1]))
    history.note(place([2], in: .playlist(7)))
    history.remove { $0 == .playlist(7) }
    history.settle()
    #expect(history.steps == [place([1])])
}

@Test func undoFirstReturnsToTheStepTheWindowMovedOffAndRedoToWhereItWasLeft() {
    var history = SelectionHistory()
    record(&history, place([1]))
    record(&history, place([2], top: 10))
    // Another source shown, with nothing selected in it.
    #expect(history.canUndo(from: place([], in: .history)))
    #expect(history.undo(from: place([], in: .history)) == place([2], top: 10))
    // Scrolled since: redo comes back to where it was left.
    #expect(history.undo(from: place([2], top: 30)) == place([1], top: 10))
    #expect(history.redo(from: place([1], top: 10)) == place([2], top: 30))
}

@Test func theOldestStepsGoPastTheLimit() {
    var history = SelectionHistory()
    for id in 0..<Int64(SelectionHistory.limit + 5) { record(&history, place([id])) }
    #expect(history.steps.count == SelectionHistory.limit)
    #expect(history.steps.first == place([5]))
    #expect(history.position == SelectionHistory.limit - 1)
}

@Test func forgettingASourceDropsItsStepsAndTheRepeatsLeft() {
    var history = SelectionHistory()
    record(&history, place([1]))
    record(&history, place([2], in: .playlist(7)))
    record(&history, place([1]))
    record(&history, place([3], in: .playlist(8)))
    _ = history.undo(from: place([3], in: .playlist(8)))
    history.remove { $0 == .playlist(7) }
    #expect(history.steps == [place([1]), place([3], in: .playlist(8))])
    #expect(history.position == 0)
    history.remove { _ in true }
    #expect(history.position == nil)
    #expect(!history.canUndo(from: place([1])))
}
