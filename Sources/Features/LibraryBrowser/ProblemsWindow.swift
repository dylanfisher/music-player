import AppKit

/// Every folder the watcher couldn't scan and every file with a stored warning or failure, as
/// text the owner can read and copy.
@MainActor
final class ProblemsWindow {
    private let window: NSPanel
    private let text: NSTextView

    init() {
        let scroll = NSTextView.scrollableTextView()
        text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered,
            defer: true)
        window.title = "Library Problems"
        window.contentView = scroll
        window.isReleasedWhenClosed = false
        // A panel hides with the app by default; the list stays up while the owner checks Finder.
        window.hidesOnDeactivate = false
        window.center()
    }

    func show(_ lines: [String]) {
        text.string = lines.isEmpty ? "No problems." : lines.joined(separator: "\n")
        window.makeKeyAndOrderFront(nil)
    }
}
