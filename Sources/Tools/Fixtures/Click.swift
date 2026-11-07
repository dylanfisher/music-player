import AppKit

/// Clicks `button` as `performClick` does, when it's enabled: the next state, then the action.
/// `performClick` waits on window-server events, which starts a thread that later stops the main
/// run loop to deliver one. A test process has no `NSApp.run` to take that, so its main loop
/// returns and the process exits 0 partway through the run, without a summary (ADR 0127).
@MainActor public func click(_ button: NSButton) {
    guard button.isEnabled else { return }
    button.cell?.setNextState()
    button.sendAction(button.action, to: button.target)
}
