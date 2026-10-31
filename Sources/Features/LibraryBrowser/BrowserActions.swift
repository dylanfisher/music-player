import Foundation
import Settings

/// What the browser's views report, wired up by `LibraryBrowser`.
@MainActor
struct BrowserActions {
    /// Double-click or Return: the selected rows and the one clicked.
    var play: (IndexSet, Int) -> Void
    var playNext: (IndexSet) -> Void
    var sort: (TrackColumn, Bool) -> Void
    var layoutChanged: (TrackTableLayout) -> Void
    var failed: (String) -> Void
}
