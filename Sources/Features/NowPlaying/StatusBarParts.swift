import AppKit
import Settings

/// The playing track's parts of the status bar: art, title and artist, the format line and a
/// seek bar with its times, one view each, which the browser lays out in the user's order. The
/// minimal style puts the track on one line; the tall one gives it two, under a larger title.
/// A playback problem in the format line has a question mark after it, and a click on either
/// opens its details.
@MainActor
public final class StatusBarParts: NSObject {
    /// The text's size in the minimal style, the track table's.
    static let minimalFontPoints = 11.0
    static let seekMinimumPoints = 60.0

    let art = NSImageView()
    let seekBox = SeekBox()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let formatLabel = NSTextField(labelWithString: "")
    let problemButton = NSButton()
    /// The format line and the question mark, the format part's view.
    private let format: NSStackView
    private let track: NSStackView
    private(set) var style = StatusBarStyle.minimal
    /// The title and subtitle the model gave, kept to lay out again when the style changes.
    private var title = ""
    private var subtitle = ""
    /// Called when the problem in the format line is clicked.
    var problemClicked: () -> Void = {}

    override init() {
        format = NSStackView(views: [formatLabel, problemButton])
        track = NSStackView(views: [titleLabel, subtitleLabel])
        track.orientation = .vertical
        track.alignment = .leading
        track.spacing = 0
        // The text parts give way first; the bar keeps enough width to aim a click at.
        seekBox.bar.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.seekMinimumPoints)
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
        for label in [subtitleLabel, formatLabel] {
            label.textColor = .secondaryLabelColor
        }
        format.spacing = 2
        format.detachesHiddenViews = true
        problemButton.isBordered = false
        problemButton.image = NSImage(
            systemSymbolName: "questionmark.circle", accessibilityDescription: "Problem details")
        problemButton.toolTip = "Show the problem's details"
        problemButton.setContentHuggingPriority(.required, for: .horizontal)
        problemButton.isHidden = true
        super.init()
        problemButton.target = self
        problemButton.action = #selector(clickedProblem)
        formatLabel.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(clickedProblem)))
        apply(.minimal)
    }

    /// The view that shows `part`, or nil for a part that isn't the playing track's.
    public func view(for part: StatusPart) -> NSView? {
        switch part {
        case .art: art
        case .track: track
        case .format: format
        case .seek: seekBox
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
        subtitleLabel.isHidden = !tall
        showTrack()
    }

    func show(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        showTrack()
    }

    /// With `problem`, the line is a playback problem, which a click opens.
    func show(format: String, color: NSColor, problem: Bool) {
        formatLabel.stringValue = format
        formatLabel.textColor = color
        formatLabel.toolTip = problem ? "\(format)\nClick for details." : format
        problemButton.isHidden = !problem
    }

    @objc func clickedProblem() {
        guard !problemButton.isHidden else { return }
        problemClicked()
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
