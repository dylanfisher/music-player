import AppKit
import Artwork
import KeyChord
import Metadata

/// An album's art opened over the whole screen, centered and as large as the screen allows but
/// never past its own pixels, over a dimmed backdrop. It shows once the art is decoded off the
/// main thread at the screen's pixels and the file's pictures are listed, so it opens at its
/// final layout. When the file holds more than one picture, a strip of their thumbnails runs
/// along the bottom, its room kept before they decode, and a
/// click on one, ← and → and the buttons at the sides step through them, stopping at either
/// end, under a line saying which, "2 of 3 · Back Cover". A click anywhere else or Esc closes it, and
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
    /// The screen it covers, whose pixels the art is decoded at.
    private let screen: NSScreen
    private(set) var isClosed = false

    /// `owner` is the window the art was opened from; `image` is drawn until the art is
    /// decoded, and in its place if the decode fails.
    init(image: NSImage, screen: NSScreen, owner: NSWindow?) {
        self.screen = screen
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
        view.choose = { [weak self] in self?.showPicture($0) }
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
        orderFront()
    }

    private func orderFront() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    /// Opens on `art` from the file at `path` at its final layout: it reads the file's
    /// pictures and decodes `art` at the screen's pixels together, off the main thread, then
    /// lays out the strip, a button a picture, and the art, and only then shows the window.
    /// When the file changed since the row's art was read and `art` isn't among its pictures,
    /// it decodes the first picture instead and opens on that. The thumbnails fill their
    /// buttons as they decode. `failed` gets what went wrong; a failed decode still opens, on
    /// the art it was made with, and a failed read opens with no strip. A close before it's
    /// done drops it all, and the window never shows.
    func open(_ art: EmbeddedArt, path: String, failed: @escaping (String) -> Void) async {
        session += 1
        let opening = session
        async let decoded = decode(art, path: path)
        async let listed = Self.pictures(at: path)
        var (image, pictures) = await (decoded, listed)
        var shownArt = art
        if case .success(let list) = pictures, !list.contains(where: { $0.art == art }),
            let first = list.first
        {
            shownArt = first.art
            image = await decode(first.art, path: path)
        }
        guard opening == session, !isClosed else { return }
        switch image {
        case .success(let image): showDecoded(image)
        case .failure(let error): failed("couldn't open the art of \(path): \(error)")
        }
        switch pictures {
        case .success(let pictures): show(pictures, current: shownArt, path: path, failed)
        case .failure(let error): failed("couldn't read the pictures of \(path): \(error)")
        }
        window.contentView?.layoutSubtreeIfNeeded()
        // Not `show()`: the session is this opening's, which the thumbnails' decode keeps.
        orderFront()
    }

    /// `art` from the file at `path`, decoded off the main thread at the screen's pixels.
    private func decode(_ art: EmbeddedArt, path: String) async -> Result<CGImage, any Error> {
        let side = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
        let loader = ArtworkLoader(maxPixelSize: Int(side.rounded(.up)), capacity: 1)
        return await loader.load(art, path: path)
    }

    private func showDecoded(_ image: CGImage) {
        view.image = NSImage(cgImage: image, size: .zero)
        view.isDecoded = true
    }

    /// Every picture in the file at `path`, read off the main thread without their bytes.
    private static func pictures(at path: String) async -> Result<
        [EmbeddedPicture], MetadataError
    > {
        await blockingFileWork {
            Result { () throws(MetadataError) in
                try readMetadata(
                    at: URL(fileURLWithPath: path, isDirectory: false), pictures: true
                ).metadata.pictures
            }
        }
    }

    /// Decodes `art` from the file at `path` at the screen's pixels and shows it, as a step
    /// does. `failed` gets what went wrong, and the art shown stays.
    @discardableResult
    func load(_ art: EmbeddedArt, path: String, failed: @escaping (String) -> Void) -> Task<
        Void, Never
    > {
        let opening = session
        return Task {
            let result = await decode(art, path: path)
            guard opening == session, window.isVisible else { return }
            switch result {
            case .success(let image): showDecoded(image)
            case .failure(let error): failed("couldn't open the art of \(path): \(error)")
            }
        }
    }

    /// Steps through `pictures` from `current`, which shows already. When the file changed
    /// since the row's art was read and `current` isn't among them, it shows the first, so
    /// the picture and the line saying which agree.
    func show(
        _ pictures: [EmbeddedPicture], current: EmbeddedArt, path: String,
        _ failed: @escaping (String) -> Void
    ) {
        self.pictures = pictures
        file = (path, failed)
        view.showsSteps = pictures.count > 1
        if let index = pictures.firstIndex(where: { $0.art == current }) {
            shown = index
        } else if let first = pictures.first {
            shown = 0
            session += 1
            load(first.art, path: path, failed: failed)
        }
        view.thumbnails = Array(repeating: nil, count: pictures.count > 1 ? pictures.count : 0)
        showPlace()
        if pictures.count > 1 { loadThumbnails(path: path, failed: failed) }
    }

    /// Decodes each picture for the strip off the main thread, one at a time.
    @discardableResult
    func loadThumbnails(path: String, failed: @escaping (String) -> Void) -> Task<Void, Never> {
        let pixels = Int((ArtViewerView.thumbnailPoints * window.backingScaleFactor).rounded(.up))
        let loader = ArtworkLoader(maxPixelSize: pixels, capacity: pictures.count)
        let opening = session
        let arts = pictures.map(\.art)
        return Task {
            for (index, art) in arts.enumerated() {
                let result = await loader.load(art, path: path)
                // A step changes the session; the strip is the file's, so only a close drops it.
                guard window.isVisible, opening <= session, index < view.thumbnails.count else {
                    return
                }
                switch result {
                case .success(let image):
                    view.thumbnails[index] = NSImage(cgImage: image, size: .zero)
                case .failure(let error):
                    failed("couldn't open picture \(index + 1) of \(path): \(error)")
                }
            }
        }
    }

    /// Shows the picture at `index`, as a click on its thumbnail does.
    func showPicture(_ index: Int) { step(by: index - shown) }

    /// The strip's thumbnails as loaded, nil for one not yet; empty for one picture.
    var thumbnails: [NSImage?] { view.thumbnails }
    /// The strip's buttons, for tests.
    var thumbnailButtons: [NSButton] { view.thumbnailButtons }
    /// Where the art is drawn, for tests.
    var imageFrame: CGRect { view.imageFrame }

    /// The image shown, for tests.
    var image: NSImage? { view.image }

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
        view.chosen = shown
    }

    /// Closes it, or, before `open` shows it, keeps it from showing.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        session += 1
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        window.orderOut(nil)
        closed()
    }

    /// `image` scaled to the largest size that fits in `bounds`, centered in it. Unless
    /// `enlarging`, as the art it opened with is until its decode arrives, never past its own
    /// size: a point a pixel.
    static func frame(of image: CGSize, in bounds: CGRect, enlarging: Bool = false) -> CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        let fit = min(bounds.width / image.width, bounds.height / image.height)
        let scale = enlarging ? fit : min(fit, 1)
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
/// click or Esc. With several pictures, ← and → and the side buttons step, a strip of their
/// thumbnails along the bottom shows one clicked, and a line between the art and the strip says
/// which is shown.
private final class ArtViewerView: NSView {
    static let thumbnailPoints = 72.0
    private static let inset = 24.0
    /// The height the strip and the line take from the art, with their gaps.
    private static let stripReserve = inset + thumbnailPoints + 12 + 22 + 12

    var image: NSImage? {
        didSet { needsDisplay = true }
    }
    /// Whether `image` is the decode at the screen's pixels, which is never enlarged; the art
    /// the viewer opened with is, until then.
    var isDecoded = false
    var close: () -> Void = {}
    var step: (Int) -> Void = { _ in }
    /// Called with the picture whose thumbnail was clicked.
    var choose: (Int) -> Void = { _ in }
    var place: String {
        get { placeLabel.stringValue }
        set { placeLabel.stringValue = newValue }
    }
    var showsSteps = false {
        didSet {
            for view in [placeLabel, backButton, forwardButton, strip] {
                view.isHidden = !showsSteps
            }
            needsDisplay = true
        }
    }
    /// The strip's images, nil until decoded; a button each.
    var thumbnails: [NSImage?] = [] {
        didSet { showThumbnails() }
    }
    /// The picture shown, whose thumbnail is marked.
    var chosen = 0 {
        didSet { showThumbnails() }
    }
    private let strip = NSStackView()
    private var stripBottom: NSLayoutConstraint?
    /// The strip's buttons, in the pictures' order.
    private(set) var thumbnailButtons: [NSButton] = []
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
        strip.spacing = 10
        for view in [placeLabel, backButton, forwardButton, strip] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isHidden = true
            addSubview(view)
        }
        let inset = Self.inset
        let stripBottom = strip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        self.stripBottom = stripBottom
        NSLayoutConstraint.activate([
            strip.centerXAnchor.constraint(equalTo: centerXAnchor), stripBottom,
            strip.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: inset),
            placeLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeLabel.bottomAnchor.constraint(equalTo: strip.topAnchor, constant: -12),
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

    /// A button a thumbnail, the one shown marked by a white border; its click doesn't reach
    /// the view's, which closes the viewer.
    private func showThumbnails() {
        while thumbnailButtons.count < thumbnails.count {
            let button = NSButton(
                title: "Picture \(thumbnailButtons.count + 1)", target: self,
                action: #selector(thumbnailClicked))
            button.tag = thumbnailButtons.count
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyUpOrDown
            button.wantsLayer = true
            button.layer?.borderColor = NSColor.white.cgColor
            button.widthAnchor.constraint(equalToConstant: Self.thumbnailPoints).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.thumbnailPoints).isActive = true
            thumbnailButtons.append(button)
            strip.addArrangedSubview(button)
        }
        while thumbnailButtons.count > thumbnails.count {
            thumbnailButtons.removeLast().removeFromSuperview()
        }
        for (index, button) in thumbnailButtons.enumerated() {
            button.image = thumbnails[index]
            button.layer?.borderWidth = index == chosen ? 2 : 0
        }
    }

    @objc private func thumbnailClicked(_ sender: NSButton) { choose(sender.tag) }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.6).setFill()
        bounds.fill()
        guard let image else { return }
        image.draw(
            in: imageFrame, from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    /// The screen's visible area, which leaves out the menu bar and the Dock.
    private var visibleArea: CGRect {
        window?.screen.map { screen in
            convert(window?.convertFromScreen(screen.visibleFrame) ?? bounds, from: nil)
        } ?? bounds
    }

    /// Where the art is drawn: in the visible area, above the strip and its line when they
    /// show.
    var imageFrame: CGRect {
        guard let image else { return .zero }
        var area = visibleArea
        if showsSteps {
            area.origin.y += Self.stripReserve
            area.size.height = max(0, area.height - Self.stripReserve)
        }
        return ArtViewer.frame(of: image.size, in: area, enlarging: !isDecoded)
    }

    override func layout() {
        // The strip sits above the Dock, as the art does.
        stripBottom?.constant = -(Self.inset + visibleArea.minY - bounds.minY)
        super.layout()
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
