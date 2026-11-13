import AppKit
import Commands
import Library
import Recommender
import Settings

/// Rediscover in the browser (ADR 0206): reading the day when the source starts showing, the
/// table listing its albums' tracks, and the selected album's reasons in the panel.
extension LibraryBrowser {
    func makeRediscover() -> RediscoverModel {
        RediscoverModel(show: { [reader] in try await reader.showRediscover($0) })
    }

    func wireRediscover() {
        content.addChild(rediscoverPanel)
        rediscover.changed = { [weak self] in
            guard let self else { return }
            rediscoverPanel.show(rediscover)
        }
        rediscover.listed = { [weak self] in
            guard let self, model.filter.source == .rediscover else { return }
            Task {
                await self.model.refresh()
                self.rediscoverSelectionChanged()
            }
        }
        rediscoverPanel.refresh = { [weak self] in self?.rediscover.read() }
        rediscoverPanel.notNow = { [weak self] in self?.notNowSelection() }
    }

    /// The calls to music-recommender as set now; nil while its address or token isn't set.
    package var rediscoverService: () -> RediscoverService? {
        get { rediscover.service }
        set { rediscover.service = newValue }
    }

    /// Sends the library profile, if it changed unless forced, before Rediscover asks for a day.
    package var sendProfile: (_ force: Bool) async -> ProfileSender.Outcome {
        get { rediscover.sendProfile }
        set { rediscover.sendProfile = newValue }
    }

    /// `library.showRediscover`: whether the sidebar lists Rediscover.
    public var showsRediscoverInSidebar: Bool {
        get { sidebarController.showsRediscover }
        set { sidebarController.showsRediscover = newValue }
    }

    /// Show Rediscover: shows it, with or without its row in the sidebar.
    public func showRediscover() { show(.rediscover) }

    /// Reads the day as Rediscover starts showing.
    func readRediscoverIfShownFirst() {
        let shows = model.filter.source == .rediscover
        guard shows != rediscover.isOpen else { return }
        rediscover.isOpen = shows
        if shows { rediscover.read() }
    }

    /// Whether the panel shown takes the height Listening Stats' does.
    var showsPanelOfStatsHeight: Bool {
        shownPanel === statsPanel || shownPanel === rediscoverPanel
    }

    /// Whether Not Now applies: Rediscover shows a day and tracks are selected.
    public var canNotNow: Bool {
        model.filter.source == .rediscover && rediscover.day != nil
            && !table.table.selectedRowIndexes.isEmpty
    }

    /// Not Now: leaves the selected tracks' albums out of Rediscover for 30 days, which
    /// Edit > Undo takes back; beeps when none is one of the day's.
    public func notNowSelection() {
        guard canNotNow else { return NSSound.beep() }
        let ids = model.ids(ofRows: table.table.selectedRowIndexes)
        Task {
            let albums: [Int64]
            do {
                let byTrack = try await reader.albumIDs(ids: ids)
                albums = ids.compactMap { byTrack[$0] }.reduce(into: []) { found, id in
                    if !found.contains(id) { found.append(id) }
                }
            } catch {
                return report("couldn't read the selected tracks' albums: \(error)")
            }
            guard let marking = rediscover.notNow(albums) else { return NSSound.beep() }
            let marked = await marking.value
            guard !marked.isEmpty, let undo = content.view.window?.undoManager else { return }
            undo.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated { _ = target.rediscover.undoNotNow(marked) }
            }
            undo.setActionName(AppCommands.title(of: .notNow))
        }
    }

    /// Shows the reasons of the first selected track's album while Rediscover shows.
    func rediscoverSelectionChanged() {
        guard model.filter.source == .rediscover else { return }
        guard let first = table.table.selectedRowIndexes.first,
            let id = model.ids(ofRows: IndexSet(integer: first)).first
        else {
            rediscover.selectedAlbumID = nil
            return
        }
        Task {
            do {
                rediscover.selectedAlbumID = try await reader.albumIDs(ids: [id])[id]
            } catch {
                report("couldn't read the selected track's album: \(error)")
            }
        }
    }
}
