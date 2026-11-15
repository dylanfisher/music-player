import AppKit
import DisplayText
import Recommender
import Settings

/// Threads' panel over the track table (ADR 0208), laid out as Rediscover's: a header with the
/// seed and Refresh, over two cards: the threads, under a row of filters (ADR 0209) and All, a
/// click on one narrowing the table to its albums; and the threads the selected track's album
/// is in.
@MainActor
final class ThreadsPanel: NSViewController, SourcePanel {
    /// The panel's title, and the sidebar row's.
    static let title = "Threads"

    /// Refresh clicked: send the profile if it changed, and read the seed's threads again.
    var refresh: () -> Void = {}
    /// A line of the Threads card clicked: its thread's place among the reply's, or nil for
    /// All.
    var choose: (Int?) -> Void = { _ in }
    /// A filter changed: all four as they are now.
    var chooseFilter: (ThreadsFilter) -> Void = { _ in }

    let seedLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let refreshButton = panelRefreshButton(
        toolTip: "Send the library profile if it changed, and read this album's threads again")
    let threadsList = StatsListView()
    let otherArtistsBox = NSButton(
        checkboxWithTitle: "Other Artists Only", target: nil, action: nil)
    /// Its first item is its title; each kind after it is checked while shown.
    let kindsMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    let playedMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    let yearsMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    let problemText = NSTextField(wrappingLabelWithString: "")
    let albumText = NSTextField(wrappingLabelWithString: "")
    private(set) lazy var threadsCard = StatsCard(
        title: Self.title, body: threadsBody(), columns: 2)
    private(set) lazy var albumCard = StatsCard(
        title: RediscoverPanel.albumCardTitle, body: albumText)
    private let flow = StatsFlowView()
    private let target = ControlTarget()
    /// The filters shown, which a control's change starts from.
    private var shownFilter = ThreadsFilter.defaults
    /// The reply's place of each thread line, after All.
    private var places: [Int] = []

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
        threadsList.clicked = { [weak self] row in
            guard let self else { return }
            choose(row == 0 ? nil : places[row - 1])
        }
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
        let body = NSStackView(views: [problemText, filterRow(), verticalScroll(threadsList)])
        body.orientation = .vertical
        body.alignment = .width
        body.spacing = 6
        body.detachesHiddenViews = true
        return body
    }

    /// Other Artists Only, Kinds, Played and Years, each reporting all four as it changes.
    private func filterRow() -> NSView {
        otherArtistsBox.toolTip = "List only the threads that lead to other artists' albums"
        kindsMenu.addItem(withTitle: "")
        kindsMenu.addItems(withTitles: ThreadsKind.allCases.map(\.title))
        kindsMenu.toolTip = "The kinds of thread to list"
        kindsMenu.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        playedMenu.addItems(withTitles: ThreadsPlayed.allCases.map(\.title))
        playedMenu.toolTip = "List albums by when they were last played"
        yearsMenu.addItems(withTitles: ThreadsYears.allCases.map(\.title))
        yearsMenu.toolTip = "List albums by their year beside this album's"
        for (control, handler) in [
            (otherArtistsBox as NSControl, { [weak self] in self?.otherArtistsClicked() }),
            (kindsMenu, { [weak self] in self?.kindChosen() }),
            (playedMenu, { [weak self] in self?.playedChosen() }),
            (yearsMenu, { [weak self] in self?.yearsChosen() }),
        ] as [(NSControl, () -> Void)] {
            control.controlSize = .small
            control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            control.target = target
            control.action = #selector(ControlTarget.act(_:))
            target.handlers[ObjectIdentifier(control)] = handler
        }
        let row = NSStackView(views: [otherArtistsBox, kindsMenu, playedMenu, yearsMenu])
        row.orientation = .horizontal
        row.spacing = 8
        return row
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
        showFilter(model.filter, seedHasYear: model.reply?.seed.year != nil)
        let shown = model.shown?.threads ?? []
        places = shown.map(\.place)
        threadsList.rows =
            model.shown.map { threadsRows($0, listed: Set(model.albums.values.map(\.id))) } ?? []
        threadsList.marked =
            model.shown == nil
            ? nil : model.chosen.flatMap { places.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        threadsCard.detailLabel.stringValue =
            model.shown.map { "\(count($0.threads.count, "thread"))" } ?? ""
        albumText.stringValue =
            model.selected.map { threadsAlbumText($0, in: model.selectedThreads) }
            ?? "Select a track of one of the threads' albums to see the threads it's in."
    }

    /// Sets the controls to `filter`; Years shows Any Year, disabled, for a seed without a
    /// year.
    private func showFilter(_ filter: ThreadsFilter, seedHasYear: Bool) {
        shownFilter = filter
        otherArtistsBox.state = filter.otherArtistsOnly ? .on : .off
        kindsMenu.item(at: 0)?.title = threadsKindsTitle(hidden: filter.hiddenKinds)
        for (place, kind) in ThreadsKind.allCases.enumerated() {
            kindsMenu.item(at: place + 1)?.state = filter.hiddenKinds.contains(kind) ? .off : .on
        }
        playedMenu.selectItem(at: ThreadsPlayed.allCases.firstIndex(of: filter.played)!)
        yearsMenu.isEnabled = seedHasYear
        let years = seedHasYear ? filter.years : .anyYear
        yearsMenu.selectItem(at: ThreadsYears.allCases.firstIndex(of: years)!)
    }

    private func otherArtistsClicked() {
        var filter = shownFilter
        filter.otherArtistsOnly = otherArtistsBox.state == .on
        chooseFilter(filter)
    }

    private func kindChosen() {
        let place = kindsMenu.indexOfSelectedItem - 1
        guard ThreadsKind.allCases.indices.contains(place) else { return }
        let kind = ThreadsKind.allCases[place]
        var filter = shownFilter
        if filter.hiddenKinds.remove(kind) == nil { filter.hiddenKinds.insert(kind) }
        chooseFilter(filter)
    }

    private func playedChosen() {
        let place = playedMenu.indexOfSelectedItem
        guard ThreadsPlayed.allCases.indices.contains(place) else { return }
        var filter = shownFilter
        filter.played = ThreadsPlayed.allCases[place]
        chooseFilter(filter)
    }

    private func yearsChosen() {
        let place = yearsMenu.indexOfSelectedItem
        guard ThreadsYears.allCases.indices.contains(place) else { return }
        var filter = shownFilter
        filter.years = ThreadsYears.allCases[place]
        chooseFilter(filter)
    }
}
