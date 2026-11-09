import AppKit
import Settings

/// The downloads' item on the status bar's left, shown while an album is on its way to
/// the staging folder: a symbol and the count, a line of words, or a small bar and the count,
/// as `style` says. A click opens Downloads; a right-click picks the style.
@MainActor
final class DownloadsStatusItem: NSView {
    /// The bar's width, in points: enough to read as progress, no more.
    static let barPoints: CGFloat = 48
    static let symbol = "arrow.down.circle"

    let image = NSImageView()
    let bar = NSProgressIndicator()
    let label = NSTextField(labelWithString: "")
    private let stack: NSStackView
    private(set) var style = DownloadsStatusStyle.progress
    private(set) var status: DownloadsStatus?

    var clicked: () -> Void = {}
    var styleChosen: (DownloadsStatusStyle) -> Void = { _ in }

    init() {
        stack = NSStackView(views: [image, bar, label])
        super.init(frame: .zero)
        image.image = NSImage(
            systemSymbolName: Self.symbol, accessibilityDescription: DownloadsWindow.title)
        image.contentTintColor = .secondaryLabelColor
        image.setContentHuggingPriority(.required, for: .horizontal)
        bar.style = .bar
        bar.controlSize = .small
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.widthAnchor.constraint(equalToConstant: Self.barPoints).isActive = true
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        stack.spacing = 4
        stack.detachesHiddenViews = true
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: stack.heightAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(click)))
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    /// Shows `status` in `style`; hides for none.
    func show(_ status: DownloadsStatus?, style: DownloadsStatusStyle) {
        self.status = status
        self.style = style
        isHidden = status == nil
        guard let status else { return }
        image.isHidden = style == .progress
        bar.isHidden = style != .progress
        bar.doubleValue = status.fraction
        label.stringValue = status.text(style)
        toolTip = status.tooltip
    }

    @objc private func click() { clicked() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for choice in DownloadsStatusStyle.allCases {
            let item = NSMenuItem(
                title: choice.title, action: #selector(chose), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = choice == style ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc func chose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let choice = DownloadsStatusStyle(rawValue: raw)
        else { return }
        styleChosen(choice)
    }
}
