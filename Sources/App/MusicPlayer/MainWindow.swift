import AppKit
import LibraryBrowser
import NowPlaying
import QueueView
import Settings

/// The main window: the now-playing bar and search field across the top, then the sidebar, the
/// browser and the queue side by side. It places the features' views and reports layout
/// changes; it holds no logic of its own.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate, NSSplitViewDelegate {
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
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        super.init()
        window.title = ProcessInfo.processInfo.processName
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

        let saved = settings.frame.map {
            NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        // A frame on a display that's no longer connected would put the window out of sight.
        if let saved, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            window.setFrame(saved, display: false)
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
        dividerIndex == 0
            ? CGFloat(sidebarRange.lowerBound)
            : max(proposedMinimumPosition, splitView.bounds.width - CGFloat(queueRange.upperBound))
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        dividerIndex == 0
            ? CGFloat(sidebarRange.upperBound)
            : splitView.bounds.width - CGFloat(queueRange.lowerBound)
    }
}

private let sidebarRange = AppSettings.sidebarWidthRange
private let queueRange = AppSettings.queueWidthRange
