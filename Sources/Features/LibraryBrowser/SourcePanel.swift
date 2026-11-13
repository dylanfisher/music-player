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

/// What a panel's header says while its content is being read.
let panelReadingText = "Reading…"

/// `document` in a scroll view that scrolls it up and down, as wide as the view and as tall as
/// `height` makes it or its own size does, drawing no background: the panels' content and the
/// Listening Stats lists.
@MainActor
func verticalScroll(_ document: NSView, height: NSLayoutConstraint? = nil) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.documentView = document
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    document.translatesAutoresizingMaskIntoConstraints = false
    let clip = scroll.contentView
    NSLayoutConstraint.activate(
        [
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
        ] + (height.map { [$0] } ?? []))
    return scroll
}
