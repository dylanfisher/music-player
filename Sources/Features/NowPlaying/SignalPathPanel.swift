import AppKit
import Playback

/// A strip under the now-playing bar showing what happens to the samples between the file and the
/// device: the verdict as a badge, then the stages as boxes joined by arrows, in one row, and the
/// verdict's reasons under them. The app hands it each path the output publishes.
@MainActor
public final class SignalPathPanel: NSViewController {
    let badge = BadgeBackground()
    let badgeLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    /// The stage boxes and the arrows between them, made again for each path.
    let stages = NSStackView()
    /// The badge, then the stages.
    let verdictRow = NSStackView()
    /// The receiver's volume, shown while receiver control is connected (ADR 0093).
    let receiverRow = NSStackView()
    let receiverSlider = NSSlider(
        value: 0, minValue: SignalPathPanel.receiverRangeDecibels.lowerBound,
        maxValue: SignalPathPanel.receiverRangeDecibels.upperBound, target: nil, action: nil)
    let receiverLevel = NSTextField(labelWithString: "")
    private let receiverCell = TrackingSliderCell()
    /// Called with the level in decibels as the slider moves.
    public var setReceiverVolume: (Double) -> Void = { _ in }
    /// The path shown last, for a playback problem's details.
    public private(set) var path: SignalPath?

    /// The slider stops at 0 dB, reference level, so a slip can't take the receiver to its
    /// +18 dB top; a level above it, set on the receiver, shows at the end.
    static let receiverRangeDecibels = -80.0...0.0

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
        stages.alignment = .centerY
        stages.spacing = 6
        verdictRow.setViews([badge, stages], in: .leading)
        verdictRow.alignment = .centerY
        verdictRow.spacing = 8
        let receiverTitle = NSTextField(labelWithString: "Receiver")
        receiverTitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        receiverSlider.cell = receiverCell
        receiverSlider.minValue = Self.receiverRangeDecibels.lowerBound
        receiverSlider.maxValue = Self.receiverRangeDecibels.upperBound
        receiverSlider.controlSize = .small
        receiverSlider.isContinuous = true
        receiverSlider.target = self
        receiverSlider.action = #selector(slid(_:))
        receiverSlider.setAccessibilityLabel("Receiver volume")
        receiverSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        receiverLevel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        receiverLevel.textColor = .secondaryLabelColor
        receiverRow.setViews([receiverTitle, receiverSlider, receiverLevel], in: .leading)
        receiverRow.spacing = 8
        receiverRow.isHidden = true
        let stack = NSStackView(views: [verdictRow, detailLabel, receiverRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 8, right: 10)
        stack.setClippingResistancePriority(.required, for: .vertical)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.widthAnchor.constraint(
            equalTo: stack.widthAnchor, constant: -stack.edgeInsets.left - stack.edgeInsets.right
        ).isActive = true
        verdictRow.translatesAutoresizingMaskIntoConstraints = false
        verdictRow.widthAnchor.constraint(
            lessThanOrEqualTo: stack.widthAnchor,
            constant: -stack.edgeInsets.left - stack.edgeInsets.right
        ).isActive = true
        view = stack
        show(nil)
    }

    /// Shows `path`, or no output when it's nil.
    public func show(_ path: SignalPath?) {
        self.path = path
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

    /// Shows the slider at `decibels` while the receiver is connected, and hides it otherwise.
    /// A connected receiver that hasn't said its level yet has the slider disabled. A level
    /// that comes while the slider is dragged is left for the drag's own.
    public func showReceiver(connected: Bool, decibels: Double?) {
        _ = view
        receiverRow.isHidden = !connected
        receiverSlider.isEnabled = decibels != nil
        guard let decibels, !receiverCell.isTracking else {
            receiverLevel.stringValue = decibels.map(Self.levelText) ?? ""
            return
        }
        receiverSlider.doubleValue = decibels
        receiverLevel.stringValue = Self.levelText(decibels)
    }

    @objc private func slid(_ slider: NSSlider) {
        let decibels = (slider.doubleValue * 2).rounded() / 2
        receiverLevel.stringValue = Self.levelText(decibels)
        setReceiverVolume(decibels)
    }

    /// `-35.5 dB`, `0.0 dB`, `+3.0 dB` as the receiver's display has it.
    static func levelText(_ decibels: Double) -> String {
        // A drag rounded to a half step can give -0, which would print as "-0.0".
        String(format: decibels > 0 ? "+%.1f dB" : "%.1f dB", decibels == 0 ? 0 : decibels)
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

/// A slider cell that says when the mouse holds it, so a status line doesn't move the knob
/// from under a drag.
final class TrackingSliderCell: NSSliderCell {
    private(set) var isTracking = false

    override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
        isTracking = true
        return super.startTracking(at: startPoint, in: controlView)
    }

    override func stopTracking(
        last lastPoint: NSPoint, current stopPoint: NSPoint, in controlView: NSView,
        mouseIsUp flag: Bool
    ) {
        isTracking = false
        super.stopTracking(last: lastPoint, current: stopPoint, in: controlView, mouseIsUp: flag)
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
