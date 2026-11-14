import AppKit
import Commands
import DisplayText
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
    /// The title of the card of the selected album, which Threads' panel shares.
    static let albumCardTitle = "Why This Album"

    /// Refresh clicked: send the profile if it changed, and read the day again.
    var refresh: () -> Void = {}
    /// Not Now clicked, for the selected album.
    var notNow: () -> Void = {}

    let dayLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let refreshButton = panelRefreshButton(
        toolTip: "Send the library profile if it changed, and read today's albums again")
    let factsText = NSTextField(wrappingLabelWithString: "")
    let threadsText = NSTextField(wrappingLabelWithString: "")
    let reasonsText = NSTextField(wrappingLabelWithString: "")
    let notNowButton = NSButton(title: AppCommands.title(of: .notNow), target: nil, action: nil)
    private(set) lazy var dayCard = StatsCard(title: "Today", body: factsText)
    private(set) lazy var threadsCard = StatsCard(
        title: ThreadsPanel.title, body: threadsText, columns: 2)
    private(set) lazy var albumCard = StatsCard(
        title: Self.albumCardTitle, body: reasonsText, accessory: notNowButton)
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
        refreshButton.target = target
        refreshButton.action = #selector(ControlTarget.act(_:))
        target.handlers[ObjectIdentifier(refreshButton)] = { [weak self] in self?.refresh() }
        notNowButton.bezelStyle = .rounded
        notNowButton.controlSize = .small
        notNowButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        notNowButton.toolTip =
            "Leave this album out of Rediscover for \(RecommenderClient.notNowDays) days."
            + " Edit > Undo puts it back."
        notNowButton.target = target
        notNowButton.action = #selector(ControlTarget.act(_:))
        target.handlers[ObjectIdentifier(notNowButton)] = { [weak self] in self?.notNow() }
        for text in [factsText, threadsText, reasonsText] {
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.isSelectable = true
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        flow.cards = [dayCard, threadsCard, albumCard]
        view = cardsPanel(
            header: [title, dayLabel, statusLabel, spacer, refreshButton], cards: flow)
    }

    func sourceShown(_ source: BrowserSource) { _ = view }

    /// Shows what the model has: the day and its facts, or what went wrong; the threads; the
    /// selected album's reasons; "Reading…" while a read is out.
    func show(_ model: RediscoverModel) {
        _ = view
        statusLabel.stringValue =
            model.isReading ? panelReadingText : model.problem.flatMap(rediscoverStatusText) ?? ""
        dayLabel.stringValue = model.day.map { rediscoverDayTitle($0.facts.day) } ?? ""
        let facts = model.day.map(rediscoverFactsText)
        let problem = model.problem.map(rediscoverProblemText)
        let notice = model.notice.map(terminalSafe)
        factsText.stringValue =
            [facts, problem, notice].compactMap { $0 }.joined(separator: "\n\n")
        factsText.textColor = problem == nil && notice == nil ? .labelColor : .systemRed
        threadsText.stringValue = model.day.map(rediscoverThreadsText) ?? ""
        reasonsText.stringValue =
            model.selected.map(rediscoverReasonsText)
            ?? "Select a track of one of the day's albums to see why it's here."
        notNowButton.isEnabled = model.selected != nil
    }
}
