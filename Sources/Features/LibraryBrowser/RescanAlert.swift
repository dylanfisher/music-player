import AppKit
import Library

/// Asks whether to rebuild the index and rescan, before the rebuild drops anything
/// (ADR 0136); answers true for Rescan Now. Modal, as it comes before the window exists.
@MainActor
public func askToRescan(_ notice: RescanNotice) -> Bool {
    let alert = NSAlert()
    alert.messageText = notice.title
    alert.informativeText = notice.text
    alert.addButton(withTitle: "Rescan Now")
    alert.addButton(withTitle: "Quit")
    return alert.runModal() == .alertFirstButtonReturn
}
