import Commands
import Foundation
import KeyChord
import Settings

/// What the browser's views report, wired up by `LibraryBrowser`.
@MainActor
struct BrowserActions {
    /// Double-click or Return: the selected rows and the one clicked.
    var play: (IndexSet, Int) -> Void
    var playNext: (IndexSet) -> Void
    /// Rows dragged within a playlist: their track IDs, and the row they go before.
    var move: ([Int64], Int) -> Void
    var sort: (TrackColumn, Bool) -> Void
    var layoutChanged: (TrackTableLayout) -> Void
    var failed: (String) -> Void
    /// A key press for the registry: runs its command, if it has one.
    var keyCommand: ([KeyChord]) -> CommandDispatcher.KeyOutcome
}
