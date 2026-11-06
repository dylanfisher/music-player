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
            guard let report = statsModel.periodReport else { return }
            let period = statsModel.period
            Task { await self.model.showStatsSpan(report.span, of: period) }
        }
        statsModel.failed = { [weak self] message in self?.report(message) }
        statsPanel.choosePeriod = { [weak self] period in self?.show(.stats(period)) }
        statsPanel.chooseRanking = { [weak self] ranking in self?.statsModel.ranking = ranking }
        statsPanel.showReview = { [weak self] year in self?.showYearInReview(year) }
        statsPanel.clearFilter = { [weak self] in
            guard let self, case .stats(let period) = model.filter.source else { return }
            filterStats(nil, in: period)
        }
        statsPanel.cards.actions = statsActions { [weak self] in
            self?.shownStatsPeriod ?? .month
        }
    }

    /// What a click in the cards of `period` does (ADR 0105): a row or bar narrows Stats'
    /// table to its tracks played in the period, or the marked one lists them all again; a
    /// bar's double-click shows its plays on the timeline.
    private func statsActions(period: @escaping @MainActor () -> StatsPeriod) -> StatsActions {
        StatsActions(
            showEntry: { [weak self] list, entry in
                guard let id = entry.id, entry.inLibrary else { return }
                self?.toggleStats(StatsFilter(.entry(list, id), title: entry.name), in: period())
            },
            showSpan: { [weak self] span, title in
                self?.toggleStats(StatsFilter(.span(span), title: title), in: period())
            },
            showPlays: { [weak self] span in
                self?.bringWindowForward()
                self?.show(.plays(span))
            },
            savePlaylist: { [weak self] name, ids, window in
                self?.saveStatsList(named: name, ids, over: window)
            })
    }

    /// Narrows Stats' table to `filter`, or lists every track again when it's the one shown.
    private func toggleStats(_ filter: StatsFilter, in period: StatsPeriod) {
        let shown = model.filter.source == .stats(period) && model.filter.stats == filter
        filterStats(shown ? nil : filter, in: period)
    }

    /// Shows Stats for `period` in the main window with its table narrowed to `filter`, or to
    /// nothing for nil, and selects a track narrowed to.
    private func filterStats(_ filter: StatsFilter?, in period: StatsPeriod) {
        bringWindowForward()
        Task {
            await model.filterStats(filter, in: period)
            showSource()
            if case .entry(.tracks, _) = filter?.item, !model.trackIDs.isEmpty {
                showRow(0)
            } else {
                focusTracks()
            }
        }
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
            year ?? statsModel.period.reviewYear()
            ?? Calendar.current.component(.year, from: Date())
        Task {
            do {
                let report = try await readStats(.chosenYear(year))
                let window = yearReview ?? YearReviewWindow()
                if yearReview == nil {
                    window.cards.actions = statsActions { [weak window] in
                        window?.year.map(StatsPeriod.chosenYear) ?? .year
                    }
                    yearReview = window
                }
                window.show(report, year: year, ranking: statsModel.ranking)
                window.showWindow(nil)
            } catch {
                self.report("couldn't read the year in review: \(error)")
            }
        }
    }

    /// Asks over the window whose list it is for a name, filled in with `name`, then makes a
    /// manual playlist of `ids` and shows it in the main window.
    private func saveStatsList(named name: String, _ ids: [Int64], over window: NSWindow?) {
        guard !ids.isEmpty else {
            NSSound.beep()
            return
        }
        guard let window else {
            return report("couldn't save the list: its window isn't open")
        }
        askForName(StatsCards.saveTitle, button: "Save", initial: name, over: window) {
            [weak self] name in
            guard let self else { return }
            bringWindowForward()
            edit(playlistFailure(name), entriesChange: true) {
                try await self.model.createPlaylist(named: name, rules: nil, trackIDs: ids)
            }
        }
    }

    /// Year in Review is a window of its own; what it shows goes in the main one.
    private func bringWindowForward() { content.view.window?.makeKeyAndOrderFront(nil) }
}

/// A report's days as a saved list's name says them, so the name stays right after the period
/// moves on: "Oct 8 – Nov 6, 2026", "2025" for a whole year, "All Time" for no bounds.
func statsPlaylistPeriod(_ span: PlaySpan?, calendar: Calendar = .current) -> String {
    guard let span else { return StatsPeriod.all.title }
    let start = Date(timeIntervalSince1970: TimeInterval(span.start))
    if let year = calendar.dateInterval(of: .year, for: start), PlaySpan(year) == span {
        return String(calendar.component(.year, from: start))
    }
    return span.title(calendar: calendar)
}
