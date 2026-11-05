import AppKit
import Library
import Settings

/// Listening Stats in the browser (ADR 0102): reading a period's report when Stats shows, and
/// what its rows, bars and buttons do.
extension LibraryBrowser {
    func wireStats() {
        statsModel.changed = { [weak self] in
            guard let self else { return }
            statsPanel.show(statsModel)
        }
        statsModel.failed = { [weak self] message in self?.report(message) }
        statsPanel.choosePeriod = { [weak self] period in self?.show(.stats(period)) }
        statsPanel.chooseRanking = { [weak self] ranking in self?.statsModel.ranking = ranking }
        statsPanel.showReview = { [weak self] year in self?.showYearInReview(year) }
        statsPanel.cards.actions = statsActions()
    }

    /// What a click in the cards does: a top artist or album shows it as Go to Item does, a
    /// genre filters to it, a track is selected in the table below, a bar shows its plays.
    private func statsActions() -> StatsActions {
        StatsActions(
            showEntry: { [weak self] list, entry in self?.showStatsEntry(list, entry) },
            showSpan: { [weak self] span in
                self?.bringWindowForward()
                self?.show(.plays(span))
            },
            savePlaylist: { [weak self] list in self?.saveStatsList(list) })
    }

    /// The report of `period`, read on Listening Stats' own connection.
    func readStats(_ period: StatsPeriod) async throws -> StatsReport {
        let stats: StatsReader
        if let statsReader {
            stats = statsReader
        } else {
            stats = try await reader.statsReader()
            statsReader = statsReader ?? stats
        }
        return try await stats.report(period, groupByAlbumArtist: model.filter.groupByAlbumArtist)
    }

    /// Reads the period's report as Stats starts showing, or shows another period.
    func readStatsIfShownFirst() {
        guard case .stats(let period) = model.filter.source else {
            statsShownPeriod = nil
            return
        }
        guard statsShownPeriod != period else { return }
        statsShownPeriod = period
        Task { await statsModel.show(period) }
    }

    /// Shows Listening Stats for `period`, or the period it showed last.
    public func showStats(_ period: StatsPeriod? = nil) {
        show(.stats(period ?? shownStatsPeriod))
    }

    /// The period Stats shows, or showed last.
    public var shownStatsPeriod: StatsPeriod { sidebarController.statsPeriod }

    /// The report of `period` as the command line prints it: text, or JSON.
    public func statsText(_ period: StatsPeriod, json: Bool) async throws -> String {
        let report = try await readStats(period)
        return json
            ? try statsJSON(report, period: period)
            : statsSummary(report, period: period, ranking: statsModel.ranking)
    }

    /// Year in Review's window, once it has opened.
    public var yearReviewWindow: NSWindow? { yearReview?.window }

    /// Opens Year in Review for `year`, or the year Stats shows, else this one.
    public func showYearInReview(_ year: Int? = nil) {
        let year =
            year ?? statsModel.period.reviewYear() ?? Calendar.current.component(.year, from: Date())
        Task {
            do {
                let report = try await readStats(.chosenYear(year))
                let window = yearReview ?? YearReviewWindow()
                if yearReview == nil {
                    window.cards.actions = statsActions()
                    yearReview = window
                }
                window.show(report, year: year, ranking: statsModel.ranking)
                window.showWindow(nil)
            } catch {
                self.report("couldn't read the year in review: \(error)")
            }
        }
    }

    private func showStatsEntry(_ list: StatsReport.List, _ entry: StatsReport.Entry) {
        guard let id = entry.id, entry.inLibrary else { return }
        bringWindowForward()
        Task {
            switch list {
            case .artists: await showFirstTrack(of: .artist, id: id)
            case .albums: await showFirstTrack(of: .album, id: id)
            case .genres: await showOnly(.genre, id: id)
            case .tracks:
                if case .stats = model.filter.source, let row = model.rows(holding: [id]).first {
                    showRow(row)
                    focusTracks()
                } else {
                    await reveal(trackID: id)
                }
            }
        }
    }

    /// Makes a manual playlist of the tracks a list's rows were played through, in its order,
    /// named for the list and the period, and shows it.
    private func saveStatsList(_ list: StatsReport.List) {
        guard let report = statsModel.report else { return }
        let entries = Array(report.list(list, by: statsModel.ranking).prefix(StatsReport.listLength))
        let ids = report.trackIDs(of: entries, in: list)
        guard !ids.isEmpty else {
            NSSound.beep()
            return
        }
        let name = list.title + ", " + statsPlaylistPeriod(statsModel.period, report.span)
        edit("couldn't make the playlist \"\(name)\"", entriesChange: true) {
            try await self.model.createPlaylist(named: name, rules: nil, trackIDs: ids)
        }
    }

    /// Year in Review is a window of its own; what it shows goes in the main one.
    private func bringWindowForward() { content.view.window?.makeKeyAndOrderFront(nil) }
}

/// The period as a saved list's name says it, so the name stays right after the period moves
/// on: "Nov 1 – 30, 2026", "2025", "All Time".
func statsPlaylistPeriod(_ period: StatsPeriod, _ span: PlaySpan?) -> String {
    switch period {
    case .week, .month: span?.title() ?? period.title
    case .year, .chosenYear: span.map { String(Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval($0.start)))) } ?? period.title
    case .all: period.title
    }
}
