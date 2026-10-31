import AppKit
import LibraryBrowser
import NowPlaying
import QueueView
import Settings

/// The app's name, as the window title and the app menu show it.
let appName = ProcessInfo.processInfo.processName

/// The main window: the now-playing bar and search field across the top, then the sidebar, the
/// browser and the queue side by side. It places the features' views and reports layout
/// changes; it holds no logic of its own.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate, NSSplitViewDelegate {
    /// The window's size before it has a saved frame: inside a 1440 by 900 screen, the 2015
    /// MacBook Pro's, with room for the default columns beside the sidebar and the queue.
    static let defaultSize = NSSize(width: 1280, height: 760)
    let window: NSWindow
    private let split = NSSplitView()
    private let browser: LibraryBrowser
    private let queue: QueuePanel
    private let saver: LayoutSaver
    private var queueWidth: Int
    private var restoring = true

    init(
        settings: WindowSettings, browser: LibraryBrowser, nowPlaying: NowPlayingBar,
        queue: QueuePanel, saver: LayoutSaver
    ) {
        self.browser = browser
        self.queue = queue
        self.saver = saver
        queueWidth = settings.queueWidth
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        super.init()
        window.title = appName
        window.minSize = NSSize(width: 720, height: 420)
        window.delegate = self
        window.isReleasedWhenClosed = false

        browser.searchField.translatesAutoresizingMaskIntoConstraints = false
        browser.searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let top = NSStackView(views: [nowPlaying.view, browser.searchField])
        top.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 10)
        top.distribution = .fill
        top.setClippingResistancePriority(.required, for: .vertical)
        (nowPlaying.view as? NSStackView)?.setHuggingPriority(.init(1), for: .horizontal)

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(browser.sidebar.view)
        split.addArrangedSubview(browser.content.view)
        split.addArrangedSubview(queue.view)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 2)
        queue.view.isHidden = !settings.queueVisible

        let line = NSBox()
        line.boxType = .separator
        let stack = NSStackView(views: [top, line, split])
        stack.orientation = .vertical
        stack.spacing = 0
        for view in [top, line, split] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window.contentView = stack

        if let frame = restoredFrame(
            settings.frame, screens: NSScreen.screens.map(\.visibleFrame))
        {
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
        window.layoutIfNeeded()
        split.setPosition(CGFloat(settings.sidebarWidth), ofDividerAt: 0)
        placeQueueDivider()
        browser.restoreSplit()
        restoring = false
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    func toggleQueue() {
        queue.view.isHidden.toggle()
        split.adjustSubviews()
        placeQueueDivider()
        saver.set(\.queueVisible, !queue.view.isHidden)
    }

    private func placeQueueDivider() {
        guard !queue.view.isHidden else { return }
        split.setPosition(split.bounds.width - CGFloat(queueWidth), ofDividerAt: 1)
    }

    // MARK: Saving the layout

    func windowDidMove(_ notification: Notification) { saveFrame() }

    func windowDidResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard !restoring else { return }
        let frame = window.frame
        saver.set(
            \.windowFrame,
            WindowFrame(
                x: frame.minX, y: frame.minY, width: frame.width, height: frame.height))
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !restoring, window.isVisible else { return }
        let sidebar = Int(browser.sidebar.view.frame.width.rounded())
        if sidebarRange.contains(sidebar) { saver.set(\.sidebarWidth, sidebar) }
        if !queue.view.isHidden {
            let width = Int(queue.view.frame.width.rounded())
            if queueRange.contains(width), width != queueWidth {
                queueWidth = width
                saver.set(\.queueWidth, width)
            }
        }
    }

    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(
            proposedMinimumPosition,
            dividerLimits(dividerIndex, width: splitView.bounds.width).lowerBound)
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(
            proposedMaximumPosition,
            dividerLimits(dividerIndex, width: splitView.bounds.width).upperBound)
    }
}

private let sidebarRange = AppState.sidebarWidthRange
private let queueRange = AppState.queueWidthRange

/// Where the dividers may go in a split view `width` points wide, so the sidebar (divider 0) and
/// the queue (divider 1) stay within the widths Settings accepts.
func dividerLimits(_ divider: Int, width: CGFloat) -> ClosedRange<CGFloat> {
    if divider == 0 {
        return CGFloat(sidebarRange.lowerBound)...CGFloat(sidebarRange.upperBound)
    }
    return (width - CGFloat(queueRange.upperBound))...(width - CGFloat(queueRange.lowerBound))
}

/// The saved frame, unless no screen in `screens` (their visible frames) shows any of it, as when
/// the display it was on is gone. Nil means center the window.
func restoredFrame(_ saved: WindowFrame?, screens: [NSRect]) -> NSRect? {
    guard let saved else { return nil }
    let frame = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
    return screens.contains { $0.intersects(frame) } ? frame : nil
}
