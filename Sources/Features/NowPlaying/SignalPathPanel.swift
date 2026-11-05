import AppKit
import Playback

/// A strip under the now-playing bar showing what happens to the samples between the file and the
/// device: the verdict as a badge on top, the stages under it as boxes joined by arrows. The app
/// hands it each path the output publishes.
@MainActor
public final class SignalPathPanel: NSViewController {
    let badge = BadgeBackground()
    let badgeLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    /// The stage boxes and the arrows between them, made again for each path.
    let stages = NSStackView()

    public init() { super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override public func loadView() {
        badgeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .semibold)
        // A plain view under constraints: an `NSBox` sizes itself from its content view, not
        // from constraints on a label added beside it, and cut the label off.
        badge.addSubview(badgeLabel)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badgeLabel.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 6),
            badgeLabel.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -6),
            badgeLabel.topAnchor.constraint(equalTo: badge.topAnchor, constant: 1),
            badgeLabel.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -1),
        ])
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let verdict = NSStackView(views: [badge, detailLabel])
        verdict.alignment = .top
        verdict.spacing = 6
        stages.alignment = .centerY
        stages.spacing = 6
        let stack = NSStackView(views: [verdict, stages])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 8, right: 10)
        stack.setClippingResistancePriority(.required, for: .vertical)
        verdict.translatesAutoresizingMaskIntoConstraints = false
        verdict.widthAnchor.constraint(
            equalTo: stack.widthAnchor, constant: -stack.edgeInsets.left - stack.edgeInsets.right
        ).isActive = true
        stages.translatesAutoresizingMaskIntoConstraints = false
        stages.widthAnchor.constraint(
            lessThanOrEqualTo: stack.widthAnchor,
            constant: -stack.edgeInsets.left - stack.edgeInsets.right
        ).isActive = true
        view = stack
        show(nil)
    }

    /// Shows `path`, or no output when it's nil.
    public func show(_ path: SignalPath?) {
        _ = view
        let lines = signalPathLines(path)
        badgeLabel.stringValue = lines.badge
        let color: NSColor =
            switch lines.tone {
            case .bitPerfect: .systemGreen
            case .changed: .systemOrange
            case .neutral: .secondaryLabelColor
            }
        badgeLabel.textColor = color
        badge.color = color.withAlphaComponent(0.15)
        detailLabel.stringValue = lines.detail
        detailLabel.isHidden = lines.detail.isEmpty
        var views: [NSView] = []
        for stage in lines.stages {
            if !views.isEmpty { views.append(arrow()) }
            views.append(box(stage))
        }
        stages.setViews(views, in: .leading)
    }

    /// A stage's title over its value and note, on a rounded fill, tinted where the samples
    /// change.
    private func box(_ stage: SignalPathLines.Stage) -> NSView {
        let title = NSTextField(labelWithString: stage.title)
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        let value = NSTextField(labelWithString: stage.value)
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let note = NSTextField(labelWithString: stage.note)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.isHidden = stage.note.isEmpty
        for field in [title, value, note] {
            field.lineBreakMode = .byTruncatingTail
            // Below a window resize, so a long name truncates instead of holding the window wide.
            field.setContentCompressionResistancePriority(.init(490), for: .horizontal)
            field.toolTip = field.stringValue
        }
        let text = NSStackView(views: [title, value, note])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let box = BadgeBackground()
        box.color =
            stage.changes
            ? NSColor.systemOrange.withAlphaComponent(0.12)
            : NSColor.labelColor.withAlphaComponent(0.06)
        box.addSubview(text)
        text.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            text.topAnchor.constraint(equalTo: box.topAnchor, constant: 4),
            text.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4),
        ])
        return box
    }

    private func arrow() -> NSView {
        let arrow = NSImageView(
            image: NSImage(systemSymbolName: "arrow.right", accessibilityDescription: "then")
                ?? NSImage())
        arrow.contentTintColor = .tertiaryLabelColor
        arrow.setContentHuggingPriority(.required, for: .horizontal)
        return arrow
    }
}

/// A rounded fill in a color that follows the appearance: the verdict's badge and each stage's
/// box.
final class BadgeBackground: NSView {
    var color = NSColor.clear {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}
