import AppKit

/// A Settings pane in a scroll view, so a pane taller than its screen scrolls rather than
/// running off it. The window is the pane's height, up to the screen's visible height less the
/// title bar and toolbar.
@MainActor
final class PaneScroller: NSViewController {
    let pane: NSViewController
    /// The visible frame of the screen the window is on; tests give a short one.
    private let visibleFrame: (NSWindow) -> NSRect?

    init(_ pane: NSViewController, visibleFrame: @escaping (NSWindow) -> NSRect?) {
        self.pane = pane
        self.visibleFrame = visibleFrame
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
        // The pane's own rows set its height; `fit` sets the window's.
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        view = scroll
    }

    /// The tallest the pane may show on `window`'s screen, or nil when it isn't on one.
    func heightLimit(in window: NSWindow) -> CGFloat? {
        guard let screen = visibleFrame(window) else { return nil }
        let chrome = window.frame.height - window.contentLayoutRect.height
        return screen.height - chrome
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        fit()
    }

    /// Sets the window to the pane's height, as far as its screen allows, keeping its top where
    /// it is unless that would put its bottom off the screen: as a pane shows, and as a
    /// disclosure in it opens or closes.
    func fit() {
        guard let window = view.window else { return }
        let limit = heightLimit(in: window)
        pane.view.layoutSubtreeIfNeeded()
        let height = min(pane.view.fittingSize.height, limit ?? .greatestFiniteMagnitude)
        let content = window.contentRect(forFrameRect: window.frame)
        var frame = window.frameRect(
            forContentRect: NSRect(
                x: content.minX, y: content.maxY - height, width: content.width, height: height))
        if let screen = visibleFrame(window), frame.minY < screen.minY {
            frame.origin.y = screen.minY
        }
        window.setFrame(frame, display: true)
    }
}

/// A clip view whose document starts at its top, as a pane is read.
private final class TopClipView: NSClipView {
    override var isFlipped: Bool { true }
}
