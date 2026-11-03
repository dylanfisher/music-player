import AppKit
import Artwork
import KeyChord
import Metadata

/// An album's art opened over the whole screen, centered and as large as the screen allows,
/// over a dimmed backdrop. It shows the art it opened with at once and replaces it with the art
/// decoded off the main thread at the screen's pixels. A click anywhere or Esc closes it, and so
/// does the window it opened from closing or the app going to the background, since it floats
/// above every window.
@MainActor
final class ArtViewer {
    let window: NSWindow
    private let view: ArtViewerView
    /// Called once the viewer has closed.
    var closed: () -> Void = {}
    /// Counts each showing and closing, so a decode finishing after the opening it was for
    /// ended is dropped.
    private var session = 0
    private var observers: [NSObjectProtocol] = []

    /// `owner` is the window the art was opened from.
    init(image: NSImage, screen: NSScreen, owner: NSWindow?) {
        window = ArtViewerWindow(
            contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        view = ArtViewerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.image = image
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .modalPanel
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrame(screen.frame, display: false)
        view.close = { [weak self] in self?.close() }
        let center = NotificationCenter.default
        let closeOnMain: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        observers = [
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main,
                using: closeOnMain)
        ]
        if let owner {
            observers.append(
                center.addObserver(
                    forName: NSWindow.willCloseNotification, object: owner, queue: .main,
                    using: closeOnMain))
        }
    }

    func show() {
        session += 1
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    /// Decodes `art` from the file at `path` at the screen's pixels and shows it. `failed` gets
    /// what went wrong, and the opening art stays.
    @discardableResult
    func load(_ art: EmbeddedArt, path: String, failed: @escaping (String) -> Void) -> Task<
        Void, Never
    > {
        let side = max(window.frame.width, window.frame.height) * window.backingScaleFactor
        let loader = ArtworkLoader(maxPixelSize: Int(side.rounded(.up)), capacity: 1)
        let opening = session
        return Task {
            let result = await Task.detached { Result { try loader.image(art, path: path) } }
                .value
            guard opening == session, window.isVisible else { return }
            switch result {
            case .success(let image): view.image = NSImage(cgImage: image, size: .zero)
            case .failure(let error): failed("couldn't open the art of \(path): \(error)")
            }
        }
    }

    func close() {
        guard window.isVisible else { return }
        session += 1
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        window.orderOut(nil)
        closed()
    }

    /// `image` scaled to the largest size that fits in `bounds`, centered in it.
    static func frame(of image: CGSize, in bounds: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
            width: size.width, height: size.height)
    }
}

/// A borderless window can't take the keys unless it says so, and Esc needs them.
private final class ArtViewerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Draws the art over a dimmed backdrop, inside the screen's visible area, and closes on a
/// click or Esc.
private final class ArtViewerView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }
    var close: () -> Void = {}

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.6).setFill()
        bounds.fill()
        guard let image else { return }
        let visible = window?.screen.map { screen in
            convert(window?.convertFromScreen(screen.visibleFrame) ?? bounds, from: nil)
        }
        image.draw(
            in: ArtViewer.frame(of: image.size, in: visible ?? bounds), from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    override func mouseDown(with event: NSEvent) { close() }

    override func keyDown(with event: NSEvent) {
        if KeyChord.candidates(for: event).first == KeyChord(.escape) {
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}
