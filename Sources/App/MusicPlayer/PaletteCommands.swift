import AppKit
import Commands
import KeyChord
import Library
import LibraryBrowser
import Log
import Palette
import Settings

private let logger = moduleLogger()

/// ⌘K and ⌘P: what each palette lists and what choosing a row does.
extension AppDelegate {
    func makePalette(
        _ dispatcher: CommandDispatcher, state: StateStore<AppState>, saver: LayoutSaver
    ) {
        let palette = PaletteController(
            model: PaletteModel(frecency: Frecency(state[\.paletteVisits])))
        palette.closingChords = { [weak dispatcher] mode in
            let id: CommandID = mode == .commands ? .showPalette : .goToItem
            // Only chords a menu could show: the field types a plain one.
            return (dispatcher?.bindings.registry.command(id)?.chords ?? []).filter(
                \.canBeKeyEquivalent)
        }
        palette.open = { [weak dispatcher] mode in
            dispatcher?.run(mode == .commands ? .showPalette : .goToItem)
        }
        palette.placeChanged = { saver.set(\.palettePlace, $0) }
        palette.visited = { [weak palette] in
            guard let palette else { return }
            saver.set(\.paletteVisits, palette.model.frecency.log)
        }
        palette.choose = { [weak self] in self?.choose($0, filters: $1) }
        self.palette = palette
        dispatcher.handle(.showPalette, enabled: hasWindow) { [weak self] in
            self?.showPalette(.commands)
        }
        dispatcher.handle(.goToItem, enabled: hasWindow) { [weak self] in
            self?.showPalette(.goToItem)
        }
    }

    private func showPalette(_ mode: PaletteMode) {
        guard let palette, let window = window?.window, let browser, let state else { return }
        if palette.mode == mode {
            palette.close()
            return
        }
        if mode == .goToItem {
            showGoToItem(palette, over: window, place: state[\.palettePlace])
            return
        }
        let session = palette.show(
            mode,
            items: commandItems() + outputItems(outputOptionsNow(), current: currentOutput)
                + playlistItems(browser.playlists),
            over: window, place: state[\.palettePlace])
        Task {
            do {
                let (items, entries) = libraryItems(
                    try await browser.allEntries().filter {
                        listedPanes(.commands).contains($0.0)
                    })
                // A listing the palette has replaced since keeps none of these.
                guard palette.model.session == session else { return }
                paletteEntries = entries
                palette.append(items, to: session)
            } catch {
                browser.report("couldn't list the library for the palette: \(error)")
            }
        }
    }

    /// Opens ⌘P on the rows kept from the last open, and builds any the library changed since.
    private func showGoToItem(
        _ palette: PaletteController, over window: NSWindow, place: PalettePlace?
    ) {
        guard let browser, let goToEntries, let goToTracks else { return }
        let entries = goToEntries.value
        let tracks = goToTracks.value
        if let entries { paletteEntries = entries.shown }
        let session = palette.show(
            .goToItem, items: (entries?.items ?? []) + (tracks ?? []), over: window, place: place)
        if entries == nil {
            Task {
                do {
                    let (items, shown) = try await goToEntries.current()
                    // A listing the palette has replaced since keeps none of these.
                    guard palette.model.session == session else { return }
                    paletteEntries = shown
                    palette.append(items, to: session)
                } catch {
                    browser.report("couldn't list the library for the palette: \(error)")
                }
            }
        }
        if tracks == nil {
            Task {
                do {
                    palette.append(try await goToTracks.current(), to: session)
                } catch {
                    browser.report("couldn't list the tracks for Go to Item: \(error)")
                }
            }
        }
    }

    /// Go to Item's rows, built the first time ⌘P opens and kept until the library changes.
    func makeGoToListings(_ browser: LibraryBrowser) {
        goToEntries = LibraryListing { [weak browser] in
            guard let browser else { return ([], [:]) }
            return libraryItems(
                try await browser.allEntries().filter { listedPanes(.goToItem).contains($0.0) })
        }
        goToTracks = LibraryListing { [weak browser] in
            guard let browser else { return [] }
            let names = try await browser.allTrackNames()
            // Preparing 43k titles for matching takes a while, so it runs off the main actor;
            // the empty query's first rows show meanwhile.
            return await Task.detached(priority: .userInitiated) { goToItems(names) }.value
        }
    }

    /// Every command but the row keys, which move a selection the palette covers, and ⌘K itself.
    private func commandItems() -> [PaletteItem] {
        guard let dispatcher, let settings else { return [] }
        let bindings = dispatcher.bindings
        var section: [CommandID: String] = [:]
        for menu in AppMenus.commandsByMenu(appName: appName) {
            for id in menu.commands { section[id] = menu.title }
        }
        let toggles = Dictionary(
            uniqueKeysWithValues: SettingCommand.all(settings.schema).filter {
                $0.action == .toggle
            }
            .map { ($0.command.id, $0.key) })
        // Settings that aren't commands: choosing one opens the Settings window at its row.
        let settingItems = settings.schema.settings.filter {
            switch $0.kind {
            case .bool, .choice: false
            default: true
            }
        }.map {
            PaletteItem(
                kind: .setting, key: "setting:\($0.key)", title: $0.title, detail: "Setting")
        }
        return settingItems
            + bindings.registry.commands.compactMap { command in
                guard RowMove.commands[command.id] == nil, command.id != .showPalette,
                    command.runsFromMenus
                else {
                    return nil
                }
                var title = command.title
                if let key = toggles[command.id] {
                    title = SettingCommand.paletteTitle(
                        title, isOn: settings.isOn(key))
                }
                return PaletteItem(
                    kind: .command, key: "command:\(command.id)", title: title,
                    detail: section[command.id],
                    chord: command.chords.first?.symbols,
                    isEnabled: dispatcher.isEnabled(command.id))
            }
    }

    /// An artist or an album shows its first track in the whole library unless `filters`, when
    /// the panes narrow to it, as a genre always does.
    private func choose(_ item: PaletteItem, filters: Bool) {
        guard let browser, let dispatcher else { return }
        switch item.kind {
        case .command:
            let id = CommandID(String(item.key.dropFirst("command:".count)))
            if !dispatcher.run(id) { NSSound.beep() }
        case .genre, .artist, .album:
            guard let (pane, id) = paletteEntries[item.key] else { return }
            if filters || item.kind == .genre {
                Task { await browser.showOnly(pane, id: id) }
            } else {
                Task { await browser.showFirstTrack(of: pane, id: id) }
            }
        case .playlist:
            guard case .playlist(let id) = BrowserSource(text: item.key),
                browser.playlists.contains(where: { $0.id == id })
            else { return }
            browser.show(.playlist(id))
        case .track:
            guard let id = goToTrackID(item.key) else { return }
            Task { await browser.reveal(trackID: id) }
        case .output:
            guard let choice = OutputChoice(text: item.key) else { return }
            chooseOutput(choice)
        case .setting:
            settingsWindowController()?.show(setting: String(item.key.dropFirst("setting:".count)))
        }
    }

    /// A play counts toward its artist's, album's and genre's frecency.
    func countPlay(_ path: String) {
        guard let palette, let trackLookup else { return }
        do {
            guard let track = try trackLookup(path) else { return }
            for key in [
                track.artist.map(LibraryKey.artist),
                track.album.map { LibraryKey.album($0, by: track.albumEntryArtist) },
                track.genre.map(LibraryKey.genre),
            ].compactMap({ $0 }) {
                palette.model.record(key)
            }
            saver?.set(\.paletteVisits, palette.model.frecency.log)
        } catch {
            logger.error("couldn't count the play of \(path): \(error)")
        }
    }
}

/// A listing read from the library: built the first time it's asked for, then kept until the
/// library changes. A build the library changed under is returned but not kept.
@MainActor
final class LibraryListing<Value: Sendable> {
    private let build: @MainActor () async throws -> Value
    private(set) var value: Value?
    private var building: Task<Value, any Error>?
    /// Counts library changes, so a build started before one isn't kept.
    private var generation = 0

    init(_ build: @escaping @MainActor () async throws -> Value) {
        self.build = build
    }

    /// The kept value, or one built now. Callers that ask during a build share it.
    func current() async throws -> Value {
        if let value { return value }
        let mine = generation
        let task = building ?? Task { [build] in try await build() }
        building = task
        do {
            let built = try await task.value
            if mine == generation {
                value = built
                building = nil
            }
            return built
        } catch {
            if mine == generation { building = nil }
            throw error
        }
    }

    /// Drops the kept value, so the next `current` builds again.
    func libraryChanged() {
        generation += 1
        value = nil
        building = nil
    }
}

/// The palette keys of the library's entries, as both the listing and a play count them. Names
/// rather than IDs, so frecency survives a rebuilt index (ADR 0016). Genres and artists are
/// unique by name; an album is unique by its title and artist.
enum LibraryKey {
    /// By ID, which survives a rebuilt index and a rename, since playlists live with the stats;
    /// spelled as the state file saves the playlist as a source.
    static func playlist(_ id: Int64) -> String { BrowserSource.playlist(id).text }
    static func genre(_ name: String) -> String { BrowserModel.Pane.genre.keyPrefix + name }
    static func artist(_ name: String) -> String { BrowserModel.Pane.artist.keyPrefix + name }
    /// The title and artist apart by a unit separator, a control character tags don't use.
    static func album(_ title: String, by artist: String?) -> String {
        BrowserModel.Pane.album.keyPrefix + "\(title)\u{1F}\(artist ?? "")"
    }
}

/// Go to Item's rows for every track in the library, keyed `track:<id>`, whatever list shows.
func goToItems(_ names: [TrackName]) -> [PaletteItem] {
    names.map { name in
        PaletteItem(
            kind: .track, key: trackKeyPrefix + String(name.id), title: name.title,
            detail: [name.artist, name.album].compactMap { $0 }.joined(separator: " — "))
    }
}

/// The panes whose entries `mode` lists: ⌘K the genres, ⌘P the artists and albums (ADR 0016).
func listedPanes(_ mode: PaletteMode) -> Set<BrowserModel.Pane> {
    mode == .commands ? [.genre] : [.artist, .album]
}

/// The track a Go to Item key names.
func goToTrackID(_ key: String) -> Int64? {
    guard key.hasPrefix(trackKeyPrefix) else { return nil }
    return Int64(key.dropFirst(trackKeyPrefix.count))
}

private let trackKeyPrefix = "track:"

/// The palette rows for the playlists, by name.
func playlistItems(_ playlists: [Playlist]) -> [PaletteItem] {
    playlists.map { playlist in
        PaletteItem(
            kind: .playlist, key: LibraryKey.playlist(playlist.id), title: playlist.name,
            detail: playlist.isManual ? "Playlist" : "Smart Playlist")
    }
}

/// The palette rows for the library's genres, artists and albums, and the entry each key shows.
func libraryItems(_ entries: [(BrowserModel.Pane, BrowserEntry)]) -> (
    items: [PaletteItem], shown: [String: (BrowserModel.Pane, Int64)]
) {
    var items: [PaletteItem] = []
    var shown: [String: (BrowserModel.Pane, Int64)] = [:]
    for (pane, entry) in entries {
        let (kind, key): (PaletteItem.Kind, String) =
            switch pane {
            case .genre: (.genre, LibraryKey.genre(entry.name))
            case .artist: (.artist, LibraryKey.artist(entry.name))
            case .album: (.album, LibraryKey.album(entry.name, by: entry.artist))
            }
        guard shown[key] == nil else { continue }
        shown[key] = (pane, entry.id)
        items.append(
            PaletteItem(
                kind: kind, key: key, title: entry.name,
                detail: [pane.title, entry.artist].compactMap { $0 }.joined(separator: " — ")))
    }
    return (items, shown)
}
