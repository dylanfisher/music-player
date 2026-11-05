import AppKit
import Library
import Settings

/// Listening Stats' panel over the track table (ADR 0102): a header with the period picker
/// (This Week, This Month, This Year, a year from the menu, All Time), Plays or Hours for the
/// top lists, and Year in Review, over cards that flow into as many columns as the width holds
/// and scroll when the panel is short. The table below lists the period's tracks.
@MainActor
final class StatsPanel: NSViewController, SourcePanel {
    /// The calendar periods the segments stand for, in order; a chosen year is in the menu.
    static let segmentPeriods: [StatsPeriod] = [.week, .month, .year, .all]

    /// A period chosen, a ranking chosen, Year in Review for a year.
    var choosePeriod: (StatsPeriod) -> Void = { _ in }
    var chooseRanking: (StatsReport.Ranking) -> Void = { _ in }
    var showReview: (Int) -> Void = { _ in }

    let cards = StatsCards()
    let periods = NSSegmentedControl(
        labels: StatsPanel.segmentPeriods.map(\.title), trackingMode: .selectOne, target: nil,
        action: nil)
    let years = NSPopUpButton(frame: .zero, pullsDown: false)
    let rankings = NSSegmentedControl(
        labels: StatsReport.Ranking.allCases.map(\.title), trackingMode: .selectOne, target: nil,
        action: nil)
    let reviewButton = NSButton(title: YearReviewWindow.title, target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "")
    private let flow = StatsFlowView()
    private(set) var period = StatsPeriod.month
    /// The years the menu lists, latest first.
    private(set) var yearChoices: [Int] = []
    private let target = ControlTarget()

    override func loadView() {
        let title = NSTextField(labelWithString: "Listening Stats")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        for control in [periods, rankings] {
            control.controlSize = .small
            control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            control.segmentStyle = .rounded
        }
        rankings.selectedSegment = 0
        rankings.toolTip = "Rank the top lists by plays or by hours played"
        years.controlSize = .small
        years.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        years.toolTip = "Show one year"
        reviewButton.bezelStyle = .rounded
        reviewButton.controlSize = .small
        reviewButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        reviewButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        reviewButton.imagePosition = .imageLeading
        reviewButton.toolTip = "The year's listening on a page of its own"
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (control, handler) in [
            (periods as NSControl, { [weak self] in self?.periodClicked() }),
            (years, { [weak self] in self?.yearChosen() }),
            (rankings, { [weak self] in self?.rankingClicked() }),
            (reviewButton, { [weak self] in self?.reviewClicked() }),
        ] as [(NSControl, () -> Void)] {
            control.target = target
            control.action = #selector(ControlTarget.act(_:))
            target.handlers[ObjectIdentifier(control)] = handler
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [
            title, periods, years, statusLabel, spacer, rankings, reviewButton,
        ])
        header.alignment = .centerY
        header.spacing = 8
        header.setHuggingPriority(.defaultLow, for: .horizontal)

        flow.cards = cards.all
        let scroll = verticalScroll(flow, height: flow.height)
        // No background of its own, as the health panel: the window's shows around the cards.
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
        showPeriod(period, years: [Calendar.current.component(.year, from: Date())])
    }

    func sourceShown(_ source: BrowserSource) {
        _ = view
        guard case .stats(let period) = source else { return }
        showPeriod(period, years: yearChoices)
    }

    /// Shows what the model has: its period chosen, its report in the cards, "Reading…"
    /// while a newer one loads.
    func show(_ model: StatsModel) {
        _ = view
        showPeriod(model.period, years: model.years())
        rankings.selectedSegment = model.ranking == .plays ? 0 : 1
        if let report = model.report { cards.show(report, ranking: model.ranking) }
        statusLabel.stringValue = model.isLoading ? "Reading…" : ""
    }

    /// Selects `period`'s segment, or its year in the menu, which lists `years`.
    private func showPeriod(_ period: StatsPeriod, years choices: [Int]) {
        self.period = period
        if choices != yearChoices || years.numberOfItems == 0 {
            yearChoices = choices
            years.removeAllItems()
            years.addItem(withTitle: "Year")
            years.lastItem?.isEnabled = false
            years.addItems(withTitles: choices.map(String.init))
        }
        periods.selectedSegment = Self.segmentPeriods.firstIndex(of: period) ?? -1
        if case .chosenYear(let year) = period, let place = choices.firstIndex(of: year) {
            years.selectItem(at: place + 1)
        } else {
            years.selectItem(at: 0)
        }
        reviewButton.isEnabled = period.reviewYear() != nil
    }

    private func periodClicked() {
        guard Self.segmentPeriods.indices.contains(periods.selectedSegment) else { return }
        choosePeriod(Self.segmentPeriods[periods.selectedSegment])
    }

    private func yearChosen() {
        let place = years.indexOfSelectedItem - 1
        guard yearChoices.indices.contains(place) else { return }
        choosePeriod(.chosenYear(yearChoices[place]))
    }

    private func rankingClicked() {
        chooseRanking(rankings.selectedSegment == 1 ? .hours : .plays)
    }

    private func reviewClicked() {
        guard let year = period.reviewYear() else { return }
        showReview(year)
    }
}
