import AppKit
import Recommender
import Settings

/// Rediscover's panel over the track table (ADR 0206), laid out as Listening Stats': a header
/// with the day and Refresh, over cards that flow into as many columns as the width holds: the
/// day, its threads, and why the selected album is among the day's. The table below lists the
/// day's albums' tracks in the service's order.
@MainActor
final class RediscoverPanel: NSViewController, SourcePanel {
    /// The panel's title, and the sidebar row's.
    static let title = "Rediscover"

    /// Refresh clicked: send the profile if it changed, and read the day again.
    var refresh: () -> Void = {}

    let dayLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    let factsText = NSTextField(wrappingLabelWithString: "")
    let threadsText = NSTextField(wrappingLabelWithString: "")
    let reasonsText = NSTextField(wrappingLabelWithString: "")
    private(set) lazy var dayCard = StatsCard(title: "Today", body: factsText)
    private(set) lazy var threadsCard = StatsCard(
        title: "Threads", body: threadsText, columns: 2)
    private(set) lazy var albumCard = StatsCard(title: "Why This Album", body: reasonsText)
    private let flow = StatsFlowView()
    private let target = ControlTarget()

    override func loadView() {
        let title = NSTextField(labelWithString: Self.title)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        dayLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshButton.imagePosition = .imageLeading
        refreshButton.toolTip =
            "Send the library profile if it changed, and read today's albums again"
        refreshButton.target = target
        refreshButton.action = #selector(ControlTarget.act(_:))
        target.handlers[ObjectIdentifier(refreshButton)] = { [weak self] in self?.refresh() }
        for text in [factsText, threadsText, reasonsText] {
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.isSelectable = true
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [title, dayLabel, statusLabel, spacer, refreshButton])
        header.alignment = .centerY
        header.spacing = 8
        header.setHuggingPriority(.defaultLow, for: .horizontal)

        flow.cards = [dayCard, threadsCard, albumCard]
        let scroll = verticalScroll(flow, height: flow.height)
        let panel = NSView()
        for view in [header, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(view)
        }
        let inset = StatsCard.insetPoints
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: inset),
            header.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -inset),
            header.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        view = panel
    }

    func sourceShown(_ source: BrowserSource) { _ = view }

    /// Shows what the model has: the day and its facts, or what went wrong; the threads; the
    /// selected album's reasons; "Reading…" while a read is out.
    func show(_ model: RediscoverModel) {
        _ = view
        statusLabel.stringValue = model.isReading ? panelReadingText : ""
        dayLabel.stringValue = model.day.map { rediscoverDayTitle($0.facts.day) } ?? ""
        let facts = model.day.map(rediscoverFactsText)
        let problem = model.problem.map(rediscoverProblemText)
        factsText.stringValue =
            [facts, problem].compactMap { $0 }.joined(separator: "\n\n")
        factsText.textColor = problem == nil ? .labelColor : .systemRed
        threadsText.stringValue = model.day.map(rediscoverThreadsText) ?? ""
        reasonsText.stringValue =
            model.selected.map(rediscoverReasonsText)
            ?? "Select a track of one of the day's albums to see why it's here."
    }
}
