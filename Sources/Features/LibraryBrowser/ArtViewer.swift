import AppKit
import Artwork
import KeyChord
import Metadata

/// An album's art opened over the whole screen, centered and as large as the screen allows,
/// over a dimmed backdrop. It shows the art it opened with at once and replaces it with the art
/// decoded off the main thread at the screen's pixels. When the file holds more than one
/// picture, ← and → and the buttons at the sides step through them, stopping at either end,
/// under a line saying which, "2 of 3 · Back Cover". A click anywhere else or Esc closes it, and
/// so does the window it opened from closing or the app going to the background, since it
/// floats above every window.
@MainActor
final class ArtViewer {
    let window: NSWindow
    private let view: ArtViewerView
    /// Called once the viewer has closed.
    var closed: () -> Void = {}
    /// Counts each showing, closing and step, so a decode finishing after the picture it was
    /// for was left is dropped.
    private var session = 0
    private var observers: [NSObjectProtocol] = []
    /// The file's pictures, once read, and the one shown.
    private(set) var pictures: [EmbeddedPicture] = []
    private(set) var shown = 0
    /// The file the pictures are in, and where a decode reports its failure.
    private var file: (path: String, failed: (String) -> Void)?

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
        view.step = { [weak self] in self?.step(by: $0) }
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
            let result = await loader.load(art, path: path)
            guard opening == session, window.isVisible else { return }
            switch result {
            case .success(let image): view.image = NSImage(cgImage: image, size: .zero)
            case .failure(let error): failed("couldn't open the art of \(path): \(error)")
            }
        }
    }

    /// Reads every picture in the file at `path` off the main thread, for stepping, `current`
    /// being the one shown. A file of one picture shows no buttons or count.
    @discardableResult
    func readPictures(path: String, current: EmbeddedArt, failed: @escaping (String) -> Void)
        -> Task<Void, Never>
    {
        let opening = session
        return Task {
            let read = await blockingFileWork {
                Result { () throws(MetadataError) in
                    try readMetadata(at: URL(fileURLWithPath: path, isDirectory: false))
                        .metadata.pictures
                }
            }
            guard opening == session, window.isVisible else { return }
            switch read {
            case .success(let pictures): show(pictures, current: current, path: path, failed)
            case .failure(let error): failed("couldn't read the pictures of \(path): \(error)")
            }
        }
    }

    /// Steps through `pictures` from `current`, which shows already.
    func show(
        _ pictures: [EmbeddedPicture], current: EmbeddedArt, path: String,
        _ failed: @escaping (String) -> Void
    ) {
        self.pictures = pictures
        shown = pictures.firstIndex { $0.art == current } ?? 0
        file = (path, failed)
        view.showsSteps = pictures.count > 1
        showPlace()
    }

    /// "2 of 3 · Back Cover", or "2 of 3" for a picture of no type; empty for one picture.
    var placeText: String {
        guard pictures.count > 1 else { return "" }
        let place = "\(shown + 1) of \(pictures.count)"
        return pictures[shown].typeName.map { "\(place) · \($0)" } ?? place
    }

    /// Shows the picture `step` places on, stopping at either end.
    func step(by step: Int) {
        let next = min(max(shown + step, 0), pictures.count - 1)
        guard next != shown, pictures.indices.contains(next), let file else { return }
        shown = next
        session += 1
        showPlace()
        load(pictures[next].art, path: file.path, failed: file.failed)
    }

    private func showPlace() {
        view.place = placeText
        view.canStepBack = shown > 0
        view.canStepForward = shown < pictures.count - 1
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
/// click or Esc. With several pictures, ← and → and the side buttons step, and a line under the
/// art says which is shown.
private final class ArtViewerView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }
    var close: () -> Void = {}
    var step: (Int) -> Void = { _ in }
    var place: String {
        get { placeLabel.stringValue }
        set { placeLabel.stringValue = newValue }
    }
    var showsSteps = false {
        didSet {
            for view in [placeLabel, backButton, forwardButton] { view.isHidden = !showsSteps }
        }
    }
    var canStepBack: Bool {
        get { backButton.isEnabled }
        set { backButton.isEnabled = newValue }
    }
    var canStepForward: Bool {
        get { forwardButton.isEnabled }
        set { forwardButton.isEnabled = newValue }
    }
    private let placeLabel = NSTextField(labelWithString: "")
    private lazy var backButton = stepButton("chevron.left", "Previous Picture", -1)
    private lazy var forwardButton = stepButton("chevron.right", "Next Picture", 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        placeLabel.textColor = .white
        placeLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .medium)
        for view in [placeLabel, backButton, forwardButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isHidden = true
            addSubview(view)
        }
        let inset = 24.0
        NSLayoutConstraint.activate([
            placeLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            forwardButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            forwardButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    /// A borderless button that steps by `by`; its own click doesn't reach the view's, which
    /// closes the viewer.
    private func stepButton(_ symbol: String, _ title: String, _ by: Int) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(stepClicked))
        button.tag = by
        button.isBordered = false
        button.contentTintColor = .white
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            button.image = image.withSymbolConfiguration(.init(pointSize: 36, weight: .medium))
            button.imagePosition = .imageOnly
        }
        return button
    }

    @objc private func stepClicked(_ sender: NSButton) { step(sender.tag) }

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
        switch KeyChord.candidates(for: event).first {
        case KeyChord(.escape): close()
        case KeyChord(.left) where showsSteps: step(-1)
        case KeyChord(.right) where showsSteps: step(1)
        default: super.keyDown(with: event)
        }
    }
}
