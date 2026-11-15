import AppKit
import Library
import Recommender
import Settings

/// Threads in the browser (ADR 0208): Show Threads from the selection's one album, reading the
/// seed's threads as the source shows it, the table listing their albums' tracks, a thread's
/// click narrowing it, and the selected album's threads in the panel.
extension LibraryBrowser {
    func makeThreads() -> ThreadsModel {
        ThreadsModel(show: { [reader] in try await reader.showThreads($0) })
    }

    func wireThreads() {
        content.addChild(threadsPanel)
        threads.changed = { [weak self] in
            guard let self else { return }
            threadsPanel.show(threads)
        }
        threads.listed = { [weak self] in
            guard let self, model.filter.source == .threads else { return }
            Task {
                await self.model.refresh()
                self.threadsAlbumChanged()
            }
        }
        threadsPanel.refresh = { [weak self] in
            guard let self, let seed = threads.seed else { return }
            threads.read(seed)
        }
        threadsPanel.choose = { [weak self] in self?.threads.choose($0) }
        threadsPanel.chooseFilter = { [weak self] filter in
            guard let self else { return }
            threads.apply(filter)
            threads.filterChosen(filter)
        }
        threadsPanel.show(threads)
    }

    /// The call to music-recommender as set now; nil while its address or token isn't set.
    package var threadsService: () -> ThreadsService? {
        get { threads.service }
        set { threads.service = newValue }
    }

    /// The Threads panel's filters, as the settings have them (ADR 0209).
    package var threadsFilter: ThreadsFilter {
        get { threads.filter }
        set { threads.apply(newValue) }
    }

    /// Called with the Threads panel's filters as one is changed there, for the settings to
    /// keep.
    package var threadsFilterChosen: (ThreadsFilter) -> Void {
        get { threads.filterChosen }
        set { threads.filterChosen = newValue }
    }

    /// `library.showThreads`: whether the sidebar lists Threads.
    public var showsThreadsInSidebar: Bool {
        get { sidebarController.showsThreads }
        set { sidebarController.showsThreads = newValue }
    }

    /// Whether Show Threads applies: the selection is one album with one Discogs release on
    /// every track, Recommendations for Album's seed rule.
    public var canShowThreads: Bool { selectionSeed != nil }

    /// Show Threads: shows the threads of the selected album, a step Back can undo, so Back
    /// and Forward walk the seeds; beeps when the selection gives no seed.
    public func showThreadsOfSelection() {
        guard let seed = selectionSeed else { return beep() }
        Task {
            await model.showThreads(of: seed)
            showSource()
            focusTracks()
        }
    }

    /// Reads the seed's threads as Threads starts showing, or as Back, Forward or Show Threads
    /// gives it another seed.
    func readThreadsIfShown() {
        let shows = model.filter.source == .threads
        let seed = model.filter.threadsSeed
        defer { threads.isOpen = shows }
        guard shows, !threads.isOpen || seed != threads.seed, let seed else { return }
        threads.read(seed)
    }

    /// Follows a change of the selection: the seed Show Threads would take from it, and the
    /// threads of the first selected track's album while Threads shows. The seed is nil until
    /// the selection is read, so the command never acts on a selection left behind.
    func threadsSelectionChanged() {
        selectionSeed = nil
        seedReads += 1
        let mine = seedReads
        let ids = model.ids(ofRows: table.table.selectedRowIndexes)
        selectionSeedRead =
            ids.isEmpty
            ? nil
            : Task {
                do {
                    let seed = try await reader.threadsSeed(trackIDs: ids)
                    if mine == seedReads { selectionSeed = seed }
                } catch {
                    report("couldn't read the selected tracks' album: \(error)")
                }
            }
        threadsAlbumChanged()
    }

    /// Shows the threads of the first selected track's album while Threads shows.
    private func threadsAlbumChanged() {
        guard model.filter.source == .threads else { return }
        readFirstSelectedAlbum { [weak self] in self?.threads.selectedAlbumID = $0 }
    }
}
