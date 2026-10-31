import Foundation

/// The rows a double-click on `clicked` queues, in order, and the one to start at.
///
/// With several rows selected, including the clicked one, the queue is the selection in table
/// order, then the rows after the last selected one, starting at the first selected. Otherwise
/// it's every row, starting at the clicked one, so previous goes back up the list and repeat-all
/// wraps around it.
func playOrder(rowCount: Int, selected: IndexSet, clicked: Int) -> (rows: [Int], first: Int) {
    precondition((0..<rowCount).contains(clicked), "row \(clicked) is outside the table")
    guard selected.count > 1, selected.contains(clicked), let last = selected.last else {
        return (Array(0..<rowCount), clicked)
    }
    let rows = Array(selected) + ((last + 1)..<rowCount).filter { !selected.contains($0) }
    return (rows, 0)
}
