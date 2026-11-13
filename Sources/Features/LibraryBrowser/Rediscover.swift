import AppKit
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
