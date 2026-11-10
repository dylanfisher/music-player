import AppKit

extension QuitQuestion {
    /// Asks, app-modal, since a quit may come with no window open: true for Quit Anyway.
    /// Cancel is the default, so Return doesn't quit.
    @MainActor
    public func ask() -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: Self.quitAnyway).hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
