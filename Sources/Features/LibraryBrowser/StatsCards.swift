import AppKit
import Library
import Settings

/// What a click in Listening Stats asks for: a list's row shown, a bar's span shown with what it
/// covers, a bar's plays on the timeline, a list saved as a playlist. The browser decides what
/// each does.
struct StatsActions {
    var showEntry: (StatsReport.List, StatsReport.Entry) -> Void = { _, _ in }
    var showSpan: (PlaySpan, String) -> Void = { _, _ in }
    var showPlays: (PlaySpan) -> Void = { _ in }
    var savePlaylist: (StatsReport.List) -> Void = { _ in }
}

/// The cards of Listening Stats, made once and filled from each report, so a hover or a
/// list's scroll survives a new one: the totals, plays over time, the week's clock, the four
/// top lists, what was first played, and the formats. The panel and Year in Review each lay
/// out their own set.
@MainActor
final class StatsCards {
    let figures = StatsFigures()
    let chart = StatsBarChart()
    let grid = StatsHeatGrid()
    private(set) var lists: [StatsReport.List: StatsListView] = [:]
    private(set) var saveButtons: [StatsReport.List: NSButton] = [:]
    let firstList = StatsListView()
    let firstKind = NSSegmentedControl(
        labels: ["Albums", "Artists"], trackingMode: .selectOne, target: nil, action: nil)
    let shares = StatsShareBar()
    let codecList = StatsListView()

    let totalsCard: StatsCard
    let chartCard: StatsCard
    let clockCard: StatsCard
    private(set) var listCards: [StatsReport.List: StatsCard] = [:]
    let firstCard: StatsCard
    let formatsCard: StatsCard

    var actions = StatsActions()
    var calendar = Calendar.current {
        didSet {
            chart.calendar = calendar
            grid.calendar = calendar
        }
    }
    private(set) var report: StatsReport?
    private(set) var ranking = StatsReport.Ranking.plays
    /// What the list rows stand for, by list, for their clicks.
    private var entries: [StatsReport.List: [StatsReport.Entry]] = [:]
    private var firstEntries: [StatsReport.Entry] = []
    /// What the table under the panel is narrowed to, whose row or bar is marked.
    private(set) var filter: StatsFilter?
    private let target = ControlTarget()

    /// How many rows a top list shows; Year in Review shows fewer.
    let listLength: Int

    /// What a list's save button does, and the title of the sheet it opens.
    static let saveTitle = "Save as Playlist"

    init(listLength: Int = StatsReport.listLength, listHeightPoints: CGFloat = 214) {
        self.listLength = listLength
        totalsCard = StatsCard(
            title: "Totals", body: figures, columns: 4, heightPoints: 92, fillsRow: true)
        chartCard = StatsCard(title: barsTitle(.day), body: chart, columns: 2)
        clockCard = StatsCard(title: "When You Listen", body: grid)
        firstKind.selectedSegment = 0
        firstKind.controlSize = .small
        firstKind.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        firstCard = StatsCard(
            title: "First Played", body: verticalScroll(firstList), accessory: firstKind,
            heightPoints: listHeightPoints)
        let formats = NSView()
        for view in [shares, codecList] {
            view.translatesAutoresizingMaskIntoConstraints = false
            formats.addSubview(view)
        }
        NSLayoutConstraint.activate([
            shares.leadingAnchor.constraint(equalTo: formats.leadingAnchor),
            shares.trailingAnchor.constraint(equalTo: formats.trailingAnchor),
            shares.topAnchor.constraint(equalTo: formats.topAnchor),
            shares.heightAnchor.constraint(equalToConstant: 48),
            codecList.leadingAnchor.constraint(equalTo: formats.leadingAnchor),
            codecList.trailingAnchor.constraint(equalTo: formats.trailingAnchor),
            codecList.topAnchor.constraint(equalTo: shares.bottomAnchor, constant: 4),
        ])
        formatsCard = StatsCard(title: "Formats", body: formats)
        for list in StatsReport.List.allCases {
            let view = StatsListView()
            lists[list] = view
            let save = NSButton(
                image: NSImage(
                    systemSymbolName: "text.badge.plus",
                    accessibilityDescription: Self.saveTitle)
                    ?? NSImage(),
                target: target, action: #selector(ControlTarget.act(_:)))
            save.bezelStyle = .inline
            save.isBordered = false
            save.refusesFirstResponder = true
            save.toolTip = "Save as a playlist of the tracks played"
            saveButtons[list] = save
            listCards[list] = StatsCard(
                title: list.title, body: verticalScroll(view), accessory: save,
                heightPoints: listHeightPoints)
        }
        wire()
    }

    /// The panel's cards, in its order.
    var all: [StatsCard] {
        [totalsCard, chartCard, clockCard]
            + StatsReport.List.allCases.compactMap { listCards[$0] } + [firstCard, formatsCard]
    }

    private func wire() {
        chart.clicked = { [weak self] place in
            guard let self, let report, report.bars.indices.contains(place) else { return }
            let bar = report.bars[place]
            actions.showSpan(bar.span, barTitle(bar, unit: report.barUnit, calendar: calendar))
        }
        chart.doubleClicked = { [weak self] place in
            guard let self, let bar = report?.bars[place] else { return }
            actions.showPlays(bar.span)
        }
        chart.hoverChanged = { [weak self] place in self?.showChartDetail(place) }
        grid.hoverChanged = { [weak self] cell in self?.showClockDetail(cell) }
        for (list, view) in lists {
            view.clicked = { [weak self] row in
                guard let self, let entry = entries[list]?[row] else { return }
                actions.showEntry(list, entry)
            }
        }
        firstList.clicked = { [weak self] row in
            guard let self, firstEntries.indices.contains(row) else { return }
            actions.showEntry(
                firstKind.selectedSegment == 0 ? .albums : .artists, firstEntries[row])
        }
        target.handlers[ObjectIdentifier(firstKind)] = { [weak self] in
            self?.showFirstPlayed()
            self?.markFilter()
        }
        firstKind.target = target
        firstKind.action = #selector(ControlTarget.act(_:))
        for (list, button) in saveButtons {
            target.handlers[ObjectIdentifier(button)] = { [weak self] in
                self?.actions.savePlaylist(list)
            }
        }
    }

    /// Fills every card from `report`, the top lists ranked by `ranking`.
    func show(_ report: StatsReport, ranking: StatsReport.Ranking) {
        self.report = report
        self.ranking = ranking
        figures.figures = Self.figures(report)
        totalsCard.detailLabel.stringValue = Self.notes(report)
        chart.unit = report.barUnit
        chart.bars = report.bars
        chartCard.titleLabel.stringValue = barsTitle(report.barUnit)
        showChartDetail(nil)
        grid.weekdayHours = report.weekdayHours
        showClockDetail(nil)
        for list in StatsReport.List.allCases {
            let shown = Array(report.list(list, by: ranking).prefix(listLength))
            entries[list] = shown
            lists[list]?.rows = Self.rows(shown, ranking: ranking)
            saveButtons[list]?.isEnabled = shown.contains { $0.inLibrary }
        }
        showFirstPlayed()
        shares.shares = report.rateGroups
        let mostCodec = Double(report.codecs.first?.plays ?? 1)
        codecList.rows = report.codecs.map {
            StatsListView.Row(
                name: $0.name,
                value: number($0.plays) + " · "
                    + percentText(Double($0.plays) / Double(max(1, report.plays))),
                fraction: Double($0.plays) / mostCodec)
        }
        codecList.clicked = { _ in }
        markFilter()
    }

    /// Marks the row or bar the table is narrowed to, in every list it's in.
    func mark(_ filter: StatsFilter?) {
        self.filter = filter
        markFilter()
    }

    private func markFilter() {
        for (list, view) in lists {
            view.marked = entries[list].flatMap { place(of: filter, in: $0, list) }
        }
        firstList.marked = place(
            of: filter, in: firstEntries, firstKind.selectedSegment == 0 ? .albums : .artists)
        if case .span(let span) = filter?.item {
            chart.marked = report?.bars.firstIndex { $0.span == span }
        } else {
            chart.marked = nil
        }
    }

    private func place(
        of filter: StatsFilter?, in entries: [StatsReport.Entry], _ list: StatsReport.List
    ) -> Int? {
        guard case .entry(list, let id) = filter?.item else { return nil }
        return entries.firstIndex { $0.id == id && $0.inLibrary }
    }

    private func showFirstPlayed() {
        guard let report else { return }
        let showsAlbums = firstKind.selectedSegment == 0
        firstEntries = Array(
            (showsAlbums ? report.firstAlbums : report.firstArtists).prefix(listLength))
        firstCard.detailLabel.stringValue =
            albums(report.firstAlbumCount) + ", " + artists(report.firstArtistCount)
        let most = Double(firstEntries.map(\.plays).max() ?? 1)
        firstList.rows = firstEntries.map { entry in
            StatsListView.Row(
                name: entry.name, detail: entry.detail,
                value: entry.firstPlayed.map { shortDate($0, calendar: calendar) } ?? "",
                fraction: Double(entry.plays) / max(1, most))
        }
        firstList.emptyText =
            showsAlbums
            ? "No album played for the first time" : "No artist played for the first time"
    }

    private func showChartDetail(_ place: Int?) {
        guard let report else { return }
        if let place, report.bars.indices.contains(place) {
            let bar = report.bars[place]
            chartCard.detailLabel.stringValue =
                barTitle(bar, unit: report.barUnit, calendar: calendar) + " · "
                + plays(bar.plays)
        } else {
            chartCard.detailLabel.stringValue =
                report.busiestDay.map {
                    "Busiest day: " + shortDate($0.span.start, calendar: calendar) + " · "
                        + plays($0.plays)
                } ?? ""
        }
    }

    private func showClockDetail(_ cell: (weekday: Int, hour: Int)?) {
        guard let report else { return }
        if let cell {
            clockCard.detailLabel.stringValue =
                calendar.weekdaySymbols[cell.weekday - 1] + " " + grid.hourName(cell.hour)
                + " · " + plays(report.weekdayHours[cell.weekday - 1][cell.hour])
        } else {
            clockCard.detailLabel.stringValue = ""
        }
    }

    /// The totals: plays, approximate hours, tracks, artists, albums and the library's share.
    static func figures(_ report: StatsReport) -> [StatsFigures.Figure] {
        [
            .init(
                value: number(report.plays), name: StatsReport.Ranking.plays.title,
                help: report.importedPlays > 0
                    ? importedText(report.importedPlays) + ". " + importedHelp : nil),
            .init(
                value: "≈ " + number(Int((report.seconds / 3600).rounded())),
                name: "Hours, approx.",
                help: "Each play counts its track's whole length, so this is approximate."),
            .init(value: number(report.tracks), name: "Tracks"),
            .init(value: number(report.artists), name: "Artists"),
            .init(value: number(report.albums), name: "Albums"),
            .init(
                value: percentText(report.libraryShare), name: "Of the Library",
                help: "The share of the library's tracks played: "
                    + "\(number(report.playedLibraryTracks)) of \(number(report.libraryTracks))."),
        ]
    }

    /// The line under the totals: the period's days, the plays no longer in the library, the
    /// imports' dated plays and, for All Time, the plays without dates.
    static func notes(_ report: StatsReport) -> String {
        var notes: [String] = []
        if let span = report.span { notes.append(span.title()) }
        if report.missingPlays > 0 {
            notes.append(plays(report.missingPlays) + " " + missingText.lowercased())
        }
        if report.importedPlays > 0 { notes.append(importedText(report.importedPlays)) }
        if report.undatedPlays > 0 {
            notes.append(
                undatedText(report.undatedPlays) + ", not ranked")
        }
        if report.plays == 0 { notes.append("No plays in this period") }
        return notes.joined(separator: " · ")
    }

    /// A top list's rows: its rank, name, artist and plays or hours, the bar against the first.
    static func rows(_ entries: [StatsReport.Entry], ranking: StatsReport.Ranking)
        -> [StatsListView.Row]
    {
        let most =
            ranking == .plays
            ? Double(entries.first?.plays ?? 1) : max(1, entries.first?.seconds ?? 1)
        return entries.enumerated().map { place, entry in
            StatsListView.Row(
                rank: place + 1, name: entry.name, detail: entry.detail,
                value: ranking == .plays ? number(entry.plays) : hoursValue(entry.seconds),
                fraction: (ranking == .plays ? Double(entry.plays) : entry.seconds) / max(1, most),
                dimmed: !entry.inLibrary)
        }
    }
}

/// Runs the handler of the control that sent the action, for views built without a controller
/// of their own.
@MainActor
final class ControlTarget: NSObject {
    var handlers: [ObjectIdentifier: () -> Void] = [:]

    @objc func act(_ sender: NSControl) { handlers[ObjectIdentifier(sender)]?() }
}
