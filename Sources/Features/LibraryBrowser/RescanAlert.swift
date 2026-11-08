import AppKit
import Library

/// Asks whether to rebuild the index and rescan, before the rebuild drops anything
/// (ADR 0136); answers true for Rescan Now. Modal, as it comes before the window exists.
@MainActor
public func askToRescan(_ notice: RescanNotice) -> Bool {
    rescanAlert(notice, declining: "Quit").runModal() == .alertFirstButtonReturn
}

/// Asks over `window` whether to rescan for a change made while the app runs, such as
/// Separate Releases (ADR 0143); `answer` gets true for Rescan Now, false for Cancel.
@MainActor
public func askToRescan(
    _ notice: RescanNotice, over window: NSWindow, answer: @escaping @MainActor (Bool) -> Void
) {
    rescanAlert(notice, declining: "Cancel").beginSheetModal(for: window) { response in
        answer(response == .alertFirstButtonReturn)
    }
}

@MainActor
private func rescanAlert(_ notice: RescanNotice, declining: String) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = notice.title
    alert.informativeText = notice.text
    alert.addButton(withTitle: "Rescan Now")
    alert.addButton(withTitle: declining)
    return alert
}
