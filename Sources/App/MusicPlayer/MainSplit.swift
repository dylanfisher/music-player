import AppKit
import Settings

/// The sidebar, the browser and the queue side by side, as a split view controller's items, so
/// AppKit draws the sidebar's material and hides a collapsed item's divider. A plain split view
/// keeps a hidden view's divider at the window's edge, where a drag meant to resize the window
/// opens the view again.
@MainActor
final class MainSplit {
    let controller = NSSplitViewController()
    private let sidebar: NSSplitViewItem
    private let queue: NSSplitViewItem
    /// The widths last reported, so a layout pass that changes nothing saves nothing.
    private var sidebarWidth: Int
    private var queueWidth: Int
    private var restoring = true
    private var observer: (any NSObjectProtocol)?
    var sidebarWidthChanged: (Int) -> Void = { _ in }
    var queueWidthChanged: (Int) -> Void = { _ in }

    init(
        sidebar: NSViewController, content: NSViewController, queue: NSViewController,
        sidebarWidth: Int, queueWidth: Int
    ) {
        self.sidebar = NSSplitViewItem(sidebarWithViewController: sidebar)
        self.queue = NSSplitViewItem(viewController: queue)
        self.sidebarWidth = sidebarWidth
        self.queueWidth = queueWidth
        let content = NSSplitViewItem(viewController: content)
        let ranges = [
            (self.sidebar, AppState.sidebarWidthRange), (self.queue, AppState.queueWidthRange),
        ]
        for (item, range) in ranges {
            item.minimumThickness = CGFloat(range.lowerBound)
            item.maximumThickness = CGFloat(range.upperBound)
            // Only the View menu hides them, so the state saved is always what shows.
            item.canCollapse = false
            item.holdingPriority = NSLayoutConstraint.Priority(260)
        }
        content.holdingPriority = .defaultLow
        controller.splitView.isVertical = true
        controller.splitView.dividerStyle = .thin
        for item in [self.sidebar, content, self.queue] { controller.addSplitViewItem(item) }
    }

    var view: NSView { controller.view }

    var isSidebarVisible: Bool { !sidebar.isCollapsed }
    var isQueueVisible: Bool { !queue.isCollapsed }

    /// Puts the dividers at the saved widths, then hides what the saved state hides, so each
    /// comes back at its width. Call once the window has its size.
    func restore(sidebarVisible: Bool, queueVisible: Bool) {
        let split = controller.splitView
        split.layoutSubtreeIfNeeded()
        split.setPosition(CGFloat(sidebarWidth), ofDividerAt: 0)
        split.setPosition(split.bounds.width - CGFloat(queueWidth), ofDividerAt: 1)
        sidebar.isCollapsed = !sidebarVisible
        queue.isCollapsed = !queueVisible
        split.layoutSubtreeIfNeeded()
        restoring = false
        observer = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reportWidths() } }
    }

    func toggleSidebar() { sidebar.isCollapsed.toggle() }

    func toggleQueue() { queue.isCollapsed.toggle() }

    private func reportWidths() {
        guard !restoring, controller.view.window?.isVisible == true else { return }
        if let width = width(of: sidebar, in: AppState.sidebarWidthRange), width != sidebarWidth {
            sidebarWidth = width
            sidebarWidthChanged(width)
        }
        if let width = width(of: queue, in: AppState.queueWidthRange), width != queueWidth {
            queueWidth = width
            queueWidthChanged(width)
        }
    }

    /// The item's width when it shows and the setting accepts it.
    private func width(of item: NSSplitViewItem, in range: ClosedRange<Int>) -> Int? {
        guard !item.isCollapsed else { return nil }
        let width = Int(item.viewController.view.frame.width.rounded())
        return range.contains(width) ? width : nil
    }
}
