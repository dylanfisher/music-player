import AppKit
import Settings

/// A view the browser shows over the track table, in the browser columns' place, while a
/// source it belongs to is shown (ADR 0099). `LibraryBrowser.panel(for:)` names the panel of
/// each source. The panel takes the columns' height and divider, which the user resizes and the
/// window saves as for the columns, and shows whether or not Show Browser is on; the columns
/// come back when a source without a panel shows.
@MainActor
protocol SourcePanel: NSViewController {
    /// Called after each change of the list is applied while the panel shows, with the source
    /// shown, which is one `panel(for:)` gave this panel for.
    func sourceShown(_ source: BrowserSource)
}
