import AppKit

/// The windows whose frames are kept across launches, by name (ADR 0158). The app sets the
/// frames saved at the last launch, the window to center new ones on, and the save before any
/// window opens; a window then takes part with one call, `keepsFrame(as:)`.
@MainActor
public final class PlacedWindows {
    /// The one `NSWindow.keepsFrame(as:)` uses, which the app sets up at launch.
    public static let shared = PlacedWindows()

    /// Each window's frame by name: those saved at the last launch, then each as it changes.
    public var frames: [String: CGRect] = [:]
    /// Hears `frames` after a window moves or resizes, to save them.
    public var framesChanged: ([String: CGRect]) -> Void = { _ in }
    /// The window whose screen a window opening for the first time is centered on. With none,
    /// or one on no screen, it's the screen with the key window.
    public var anchor: () -> NSWindow? = { nil }
    /// Each name's window, held weakly, and its observers, removed when another window takes
    /// the name.
    private let windows = NSMapTable<NSString, NSWindow>.strongToWeakObjects()
    private var observers: [String: [any NSObjectProtocol]] = [:]

    public init() {}

    /// Puts `window` where `name` was left, or centers it on the anchor's screen, and keeps its
    /// frame under `name` as it moves and resizes, except in full screen. Once it keeps it, a
    /// second call does nothing, so a window's `show` can make it each time.
    public func place(_ window: NSWindow, as name: String) {
        guard windows.object(forKey: name as NSString) !== window else { return }
        let screen = anchor()?.screen ?? NSScreen.main
        window.setFrame(
            placedFrame(
                saved: frames[name], size: window.frame.size,
                resizable: window.styleMask.contains(.resizable),
                screens: NSScreen.screens.map(\.visibleFrame),
                anchorScreen: screen?.visibleFrame ?? window.frame),
            display: false)
        windows.setObject(window, forKey: name as NSString)
        let center = NotificationCenter.default
        observers[name]?.forEach(center.removeObserver)
        observers[name] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map {
            center.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keepFrame(of: name) }
            }
        }
    }

    private func keepFrame(of name: String) {
        guard let window = windows.object(forKey: name as NSString),
            !window.styleMask.contains(.fullScreen)
        else { return }
        frames[name] = window.frame
        framesChanged(frames)
    }
}

extension NSWindow {
    /// Opens where the window named `name` was left at the last launch, or centered on the main
    /// window's screen the first time, and keeps its frame from then on (ADR 0158). Call it once
    /// the window has its size, before it first shows; later calls do nothing.
    public func keepsFrame(as name: String) { PlacedWindows.shared.place(self, as: name) }

    /// As `keepsFrame(as:)` for the first window of a kind; while `last`, another of them, is
    /// open, it opens cascaded from it instead, at its size when it resizes, and keeps no
    /// frame, so the frame kept is the first one's.
    public func keepsFrame(as name: String, cascadedFrom last: NSWindow?) {
        guard let last else { return keepsFrame(as: name) }
        if styleMask.contains(.resizable) {
            setContentSize(last.contentRect(forFrameRect: last.frame).size)
        }
        setFrameTopLeftPoint(cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
    }
}
