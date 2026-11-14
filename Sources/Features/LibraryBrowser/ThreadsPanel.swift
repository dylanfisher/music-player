import AppKit
import DisplayText
import Recommender
import Settings

/// Threads' panel over the track table (ADR 0208), laid out as Rediscover's: a header with the
/// seed and Refresh, over two cards: the threads, All above them, a click on one narrowing the
/// table to its albums; and the threads the selected track's album is in.
@MainActor
final class ThreadsPanel: NSViewController, SourcePanel {
    /// The panel's title, and the sidebar row's.
    static let title = "Threads"

    /// Refresh clicked: send the profile if it changed, and read the seed's threads again.
    var refresh: () -> Void = {}
    /// A line of the Threads card clicked: its thread's place, or nil for All.
    var choose: (Int?) -> Void = { _ in }

    let seedLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let refreshButton = panelRefreshButton(
        toolTip: "Send the library profile if it changed, and read this album's threads again")
    let threadsList = StatsListView()
    let problemText = NSTextField(wrappingLabelWithString: "")
    let albumText = NSTextField(wrappingLabelWithString: "")
    private(set) lazy var threadsCard = StatsCard(
        title: Self.title, body: threadsBody(), columns: 2)
    private(set) lazy var albumCard = StatsCard(
        title: RediscoverPanel.albumCardTitle, body: albumText)
    private let flow = StatsFlowView()
    private let target = ControlTarget()

    override func loadView() {
        let title = NSTextField(labelWithString: Self.title)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        seedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        seedLabel.lineBreakMode = .byTruncatingTail
        seedLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshButton.target = target
        refreshButton.action = #selector(ControlTarget.act(_:))
        target.handlers[ObjectIdentifier(refreshButton)] = { [weak self] in self?.refresh() }
        threadsList.clicked = { [weak self] row in self?.choose(row == 0 ? nil : row - 1) }
        threadsList.emptyText = ""
        for text in [problemText, albumText] {
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.isSelectable = true
        }
        problemText.textColor = .systemRed
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        flow.cards = [threadsCard, albumCard]
        view = cardsPanel(
            header: [title, seedLabel, statusLabel, spacer, refreshButton], cards: flow)
    }

    /// The threads' list, with what went wrong above it; the list fills the card when nothing
    /// did.
    private func threadsBody() -> NSView {
        let body = NSStackView(views: [problemText, verticalScroll(threadsList)])
        body.orientation = .vertical
        body.alignment = .width
        body.spacing = 6
        body.detachesHiddenViews = true
        return body
    }

    func sourceShown(_ source: BrowserSource) { _ = view }

    /// Shows what the model has: the seed, or what went wrong; the threads with the chosen one
    /// marked; the selected album's threads; "Reading…" while a read is out.
    func show(_ model: ThreadsModel) {
        _ = view
        statusLabel.stringValue =
            model.isReading ? panelReadingText : model.problem.flatMap(rediscoverStatusText) ?? ""
        seedLabel.stringValue = model.reply.map { threadsSeedTitle($0.seed) } ?? ""
        let problem =
            model.seed == nil
            ? threadsNoSeedText : model.problem.map(threadsProblemText)
        problemText.stringValue = problem ?? ""
        problemText.textColor = model.seed == nil ? .secondaryLabelColor : .systemRed
        problemText.isHidden = problem == nil
        threadsList.rows =
            model.reply.map { threadsRows($0, listed: Set(model.albums.values.map(\.id))) } ?? []
        threadsList.marked = model.reply == nil ? nil : (model.chosen ?? -1) + 1
        threadsCard.detailLabel.stringValue =
            model.reply.map { "\(count($0.threads.count, "thread"))" } ?? ""
        albumText.stringValue =
            model.selected.map { threadsAlbumText($0, in: model.selectedThreads) }
            ?? "Select a track of one of the threads' albums to see the threads it's in."
    }
}
