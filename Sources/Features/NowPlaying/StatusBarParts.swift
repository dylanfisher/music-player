import AppKit
import Settings

/// The playing track's parts of the status bar: art, title and artist, the format line and a
/// seek bar with times, one view each, which the browser lays out in the user's order. The
/// minimal style puts the track on one line; the tall one gives it two, under a larger title.
@MainActor
public final class StatusBarParts {
    /// The text's size in the minimal style, the track table's.
    static let minimalFontPoints = 11.0
    static let seekMinimumPoints = 60.0

    let art = NSImageView()
    let seekBar = SeekBar()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let formatLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let remainingLabel = NSTextField(labelWithString: "")
    private let track: NSStackView
    private let seek: NSStackView
    private(set) var style = StatusBarStyle.minimal
    /// The title and subtitle the model gave, kept to lay out again when the style changes.
    private var title = ""
    private var subtitle = ""

    init() {
        track = NSStackView(views: [titleLabel, subtitleLabel])
        track.orientation = .vertical
        track.alignment = .leading
        track.spacing = 0
        seek = NSStackView(views: [elapsedLabel, seekBar, remainingLabel])
        seek.spacing = 4
        seek.distribution = .fill
        // The text parts give way first; the bar keeps enough width to aim a click at.
        seekBar.translatesAutoresizingMaskIntoConstraints = false
        seekBar.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.seekMinimumPoints)
            .isActive = true
        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.cornerRadius = 2
        art.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        art.translatesAutoresizingMaskIntoConstraints = false
        art.widthAnchor.constraint(equalTo: art.heightAnchor).isActive = true
        art.setContentHuggingPriority(.required, for: .horizontal)
        for label in [titleLabel, subtitleLabel, formatLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for label in [subtitleLabel, formatLabel, elapsedLabel, remainingLabel] {
            label.textColor = .secondaryLabelColor
        }
        elapsedLabel.alignment = .right
        apply(.minimal)
    }

    /// The view that shows `part`, or nil for a part that isn't the playing track's.
    public func view(for part: StatusPart) -> NSView? {
        switch part {
        case .art: art
        case .track: track
        case .format: formatLabel
        case .seek: seek
        case .totals: nil
        }
    }

    public func apply(_ style: StatusBarStyle) {
        self.style = style
        let tall = style == .tall
        let size = tall ? NSFont.systemFontSize : Self.minimalFontPoints
        titleLabel.font = .systemFont(ofSize: size, weight: tall ? .semibold : .regular)
        subtitleLabel.font = .systemFont(ofSize: Self.minimalFontPoints)
        formatLabel.font = .systemFont(ofSize: Self.minimalFontPoints)
        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(
                ofSize: Self.minimalFontPoints, weight: .regular)
        }
        subtitleLabel.isHidden = !tall
        showTrack()
    }

    func show(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        showTrack()
    }

    func show(format: String, color: NSColor) {
        formatLabel.stringValue = format
        formatLabel.textColor = color
        formatLabel.toolTip = format
    }

    func showTimes(elapsed: String, remaining: String) {
        elapsedLabel.stringValue = elapsed
        remainingLabel.stringValue = remaining
    }

    /// "Title — Artist — Album" on one line in the minimal style; the title over the rest in the
    /// tall one.
    private func showTrack() {
        let oneLine = style == .minimal && !subtitle.isEmpty
        titleLabel.stringValue = oneLine ? "\(title) — \(subtitle)" : title
        titleLabel.toolTip = titleLabel.stringValue
        subtitleLabel.stringValue = subtitle
    }

    /// What the minimal style's track line says, for tests.
    var trackText: String { titleLabel.stringValue }
}
