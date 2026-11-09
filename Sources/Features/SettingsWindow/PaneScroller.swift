import AppKit

/// A Settings pane in a scroll view, so a pane taller than its screen scrolls rather than
/// running off it. The window is the pane's height, up to the screen's visible height less the
/// title bar and toolbar.
@MainActor
final class PaneScroller: NSViewController {
    let pane: NSViewController
    /// The visible frame of the screen a window is on, which caps the pane's height; tests
    /// give a short one.
    var visibleFrame: (NSWindow) -> NSRect? = { ($0.screen ?? NSScreen.main)?.visibleFrame }
    private var resized: (any NSObjectProtocol)?

    init(_ pane: NSViewController) {
        self.pane = pane
        super.init(nibName: nil, bundle: nil)
        addChild(pane)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let clip = TopClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        let content = pane.view
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        // The pane's own rows set its height; `fit` sets the window's, each time the pane's
        // changes, as a disclosure opens or a refusal shows under its field.
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        content.postsFrameChangedNotifications = true
        resized = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: content, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.fit() } }
        view = scroll
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        fit()
    }

    /// Keeps the window at the pane's height, as far as its screen allows, and wholly on that
    /// screen, its top where it is when it fits: as a pane shows, and each time its height
    /// changes, whether a row shows or hides.
    func fit() {
        guard let window = view.window else { return }
        let screen = visibleFrame(window)
        pane.view.layoutSubtreeIfNeeded()
        var height = pane.view.fittingSize.height
        if let screen {
            // Less the title bar and the toolbar.
            height = min(
                height, screen.height - window.frame.height + window.contentLayoutRect.height)
        }
        let content = window.contentRect(forFrameRect: window.frame)
        var frame = window.frameRect(
            forContentRect: NSRect(
                x: content.minX, y: content.maxY - height, width: content.width, height: height))
        if let screen {
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        }
        window.setFrame(frame, display: true)
    }
}

/// A clip view whose document starts at its top, as a pane is read.
private final class TopClipView: NSClipView {
    override var isFlipped: Bool { true }
}
