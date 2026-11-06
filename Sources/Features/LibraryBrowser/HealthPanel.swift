import Analysis
import AppKit
import Commands
import DisplayText
import Library
import Settings

/// Library Health's panel over the track table (ADR 0099): a line saying when the report ran,
/// with Check Again, over a tile for each check in `HealthCheck`'s order, with its name, its
/// count and what it finds. A click on a tile lists that check's tracks below. The tiles flow
/// into as many columns as the width holds.
@MainActor
final class HealthPanel: NSViewController, SourcePanel {
    /// The narrowest a tile gets before a column is dropped, and the tiles' height and spacing.
    /// Wide enough for all but the three longest descriptions, which the tooltip shows whole.
    static let tileMinWidthPoints: CGFloat = 330
    static let tileHeightPoints: CGFloat = 46
    static let spacingPoints: CGFloat = 8
    static let insetPoints: CGFloat = 12
    /// The least height the panel opens at or is dragged to: the header, the analysis line and
    /// a row of tiles (ADR 0117). The columns, whose height it shares, can still be shut.
    static let leastHeightPoints = 110

    /// A tile clicked, and Check Again.
    var select: (HealthCheck) -> Void = { _ in }
    var checkAgain: () -> Void = {}
    /// The analysis line's button: Pause Library Analysis, or Analyze Library.
    var runCommand: (CommandID) -> Void = { _ in }
    private(set) var tiles: [HealthCheck: HealthTile] = [:]
    let statusLabel = NSTextField(labelWithString: "")
    /// Analyze Library's line (ADR 0119): its bar, what it says with the file under way, and a
    /// button that pauses it or starts it.
    let analysisBar = NSProgressIndicator()
    let analysisLabel = NSTextField(labelWithString: "")
    let analysisButton = NSButton()
    /// The command the analysis button runs now.
    private(set) var analysisCommand = CommandID.analyzeLibrary
    private let flow = TileFlowView()
    /// The check listed below, which its tile shows highlighted.
    private(set) var shownCheck: HealthCheck?

    override func loadView() {
        let title = NSTextField(labelWithString: "Library Health")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let again = NSButton(
            title: "Check Again", target: self, action: #selector(checkAgainClicked))
        again.bezelStyle = .rounded
        again.controlSize = .small
        again.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [title, statusLabel, spacer, again])
        header.alignment = .firstBaseline
        header.spacing = Self.spacingPoints
        let analysis = analysisLine()

        for check in HealthCheck.allCases {
            let tile = HealthTile(check: check)
            tile.clicked = { [weak self] in self?.select(check) }
            tiles[check] = tile
            flow.addSubview(tile)
        }
        let scroll = verticalScroll(flow, height: flow.height)

        // No background of its own: the window's, or its glass, shows around the tiles, so the
        // panel reads apart from the table's rows.
        let panel = NSView()
        for view in [header, analysis, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(view)
        }
        let inset = Self.insetPoints
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: inset),
            header.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -inset),
            header.topAnchor.constraint(equalTo: panel.topAnchor, constant: inset - 4),
            analysis.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            analysis.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            analysis.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: analysis.bottomAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        view = panel
        show(report: nil, checkedAt: nil, running: false)
        showAnalysis(nil, analyzeTitle: AppCommands.title(of: .analyzeLibrary))
    }

    /// The bar, the text and the button of Analyze Library's line.
    private func analysisLine() -> NSStackView {
        analysisBar.style = .bar
        analysisBar.controlSize = .small
        analysisBar.isIndeterminate = false
        analysisBar.minValue = 0
        analysisBar.maxValue = 1
        analysisBar.widthAnchor.constraint(equalToConstant: 120).isActive = true
        analysisLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        analysisLabel.textColor = .secondaryLabelColor
        analysisLabel.lineBreakMode = .byTruncatingMiddle
        analysisLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        analysisButton.bezelStyle = .rounded
        analysisButton.controlSize = .small
        analysisButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        analysisButton.target = self
        analysisButton.action = #selector(analysisClicked)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = NSStackView(views: [analysisBar, analysisLabel, analysisButton, spacer])
        line.alignment = .centerY
        line.spacing = Self.spacingPoints
        line.detachesHiddenViews = true
        return line
    }

    /// Shows where Analyze Library is: running, with Pause; paused, with `analyzeTitle` to carry
    /// on; or, nil, the button alone.
    func showAnalysis(_ progress: LibraryAnalysis.Progress?, analyzeTitle: String) {
        _ = view
        let running = progress?.stage.isRunning == true
        analysisBar.isHidden = progress == nil
        analysisBar.doubleValue = progress?.fraction ?? 0
        analysisLabel.isHidden = progress == nil
        analysisLabel.stringValue =
            ([progress?.text] + [running ? progress?.file : nil]).compactMap { $0 }
            .joined(separator: " · ")
        analysisCommand = Self.analysisCommand(for: progress?.stage)
        analysisButton.title = running ? AppCommands.title(of: analysisCommand) : analyzeTitle
    }

    /// What a button for Analyze Library runs, here and in the status bar: Pause Library
    /// Analysis while a run goes, and Analyze Library while it's paused or none is.
    static func analysisCommand(for stage: LibraryAnalysis.Progress.Stage?) -> CommandID {
        stage?.isRunning == true ? .pauseLibraryAnalysis : .analyzeLibrary
    }

    @objc private func analysisClicked() { runCommand(analysisCommand) }

    /// Shows the report's counts, or a dash for each before there is one, and when it ran.
    func show(report: HealthReport?, checkedAt: Date?, running: Bool) {
        _ = view
        for (check, tile) in tiles {
            tile.count = report?[check].count
            tile.summary = check.summary(analyzedCount: report?.analyzedCount)
        }
        statusLabel.stringValue =
            if running {
                "Checking…"
            } else if let checkedAt {
                "Checked at "
                    + DateFormatter.localizedString(
                        from: checkedAt, dateStyle: .none, timeStyle: .short)
            } else {
                "Not checked yet"
            }
    }

    func sourceShown(_ source: BrowserSource) {
        _ = view
        shownCheck = if case .health(let check) = source { check } else { nil }
        for (check, tile) in tiles { tile.isSelected = check == shownCheck }
    }

    @objc private func checkAgainClicked() { checkAgain() }
}

/// The tiles in rows, each row as many as fit at the narrowest width, sharing it evenly; as
/// tall as its rows, so the scroll view scrolls them.
private final class TileFlowView: NSView {
    /// The rows' height, which the width decides.
    private(set) lazy var height = heightAnchor.constraint(equalToConstant: 0)

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let inset = HealthPanel.insetPoints
        let spacing = HealthPanel.spacingPoints
        let width = max(0, bounds.width - 2 * inset)
        let columns = max(
            1, Int((width + spacing) / (HealthPanel.tileMinWidthPoints + spacing)))
        let tileWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let height = HealthPanel.tileHeightPoints
        for (place, tile) in subviews.enumerated() {
            let row = place / columns
            let column = place % columns
            tile.frame = NSRect(
                x: inset + CGFloat(column) * (tileWidth + spacing),
                y: CGFloat(row) * (height + spacing), width: tileWidth, height: height)
        }
        let rows = (subviews.count + columns - 1) / columns
        let fitted = CGFloat(rows) * (height + spacing) - spacing + inset
        if self.height.constant != fitted { self.height.constant = fitted }
    }
}

/// One check: its name and count on the first line, what it finds on the second. A check that
/// found nothing is dimmed; the one listed below is drawn in the accent color.
final class HealthTile: NSView {
    let check: HealthCheck
    var clicked: () -> Void = {}
    /// What the check found; nil before any report.
    var count: Int? {
        didSet { restyle() }
    }
    var isSelected = false {
        didSet { restyle() }
    }
    /// What the check finds, and for a measured one how many files it covers.
    var summary: String {
        get { summaryLabel.stringValue }
        set {
            summaryLabel.stringValue = newValue
            toolTip = newValue
        }
    }
    let titleLabel = NSTextField(labelWithString: "")
    let countLabel = NSTextField(labelWithString: "")
    let summaryLabel = NSTextField(labelWithString: "")
    private let background = NSBox()

    init(check: HealthCheck) {
        self.check = check
        super.init(frame: .zero)
        background.boxType = .custom
        background.borderWidth = 1
        background.cornerRadius = 6
        titleLabel.stringValue = check.title
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize, weight: .semibold)
        countLabel.alignment = .right
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [background, titleLabel, countLabel, summaryLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let inset: CGFloat = 9
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            countLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 6),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            countLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
        summary = check.summary
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    /// Whether the check found something, or hasn't run: only a zero dims the tile.
    var foundNothing: Bool { count == 0 }

    private func restyle() {
        countLabel.stringValue = count.map(number) ?? "–"
        let primary: NSColor
        let secondary: NSColor
        if isSelected {
            background.fillColor = .controlAccentColor
            background.borderColor = .clear
            primary = .alternateSelectedControlTextColor
            secondary = .alternateSelectedControlTextColor.withAlphaComponent(0.8)
        } else {
            background.fillColor = .controlBackgroundColor.withAlphaComponent(
                foundNothing ? 0.4 : 0.9)
            background.borderColor = .separatorColor
            primary = foundNothing ? .tertiaryLabelColor : .labelColor
            secondary = foundNothing ? .tertiaryLabelColor : .secondaryLabelColor
        }
        titleLabel.textColor = primary
        countLabel.textColor = primary
        summaryLabel.textColor = secondary
        setAccessibilityLabel("\(check.title), \(countLabel.stringValue)")
        setAccessibilitySelected(isSelected)
    }

    /// The labels pass their clicks to the tile.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        clicked()
    }

    override func accessibilityPerformPress() -> Bool {
        clicked()
        return true
    }
}
