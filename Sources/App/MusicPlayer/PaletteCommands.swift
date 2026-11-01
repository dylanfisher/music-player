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
        palette.choose = { [weak self] item in self?.choose(item) }
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
        switch mode {
        case .commands:
            let session = palette.show(
                .commands, items: commandItems() + playlistItems(browser.playlists), over: window,
                place: state[\.palettePlace])
            Task {
                do {
                    let (items, entries) = libraryItems(try await browser.allEntries())
                    // A listing the palette has replaced since keeps none of these.
                    guard palette.model.session == session else { return }
                    paletteEntries = entries
                    palette.append(items, to: session)
                } catch {
                    browser.report("couldn't list the library for the palette: \(error)")
                }
            }
        case .goToItem:
            let session = palette.show(
                .goToItem, items: [], over: window, place: state[\.palettePlace])
            Task {
                do {
                    let names = try await browser.trackNames()
                    // Preparing 43k titles for matching takes a while, so it runs off the main
                    // actor; the empty query's first rows show meanwhile.
                    let items = await Task.detached(priority: .userInitiated) {
                        names.enumerated().map { row, name in
                            PaletteItem(
                                kind: .track, key: "track:\(row):\(name.id)", title: name.title,
                                detail: [name.artist, name.album].compactMap { $0 }.joined(
                                    separator: " — "))
                        }
                    }.value
                    palette.append(items, to: session)
                } catch {
                    browser.report("couldn't list the tracks for Go to Item: \(error)")
                }
            }
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
                guard RowMove.commands[command.id] == nil, command.id != .showPalette else {
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

    private func choose(_ item: PaletteItem) {
        guard let browser, let dispatcher else { return }
        switch item.kind {
        case .command:
            let id = CommandID(String(item.key.dropFirst("command:".count)))
            if !dispatcher.run(id) { NSSound.beep() }
        case .genre, .artist, .album:
            guard let (pane, id) = paletteEntries[item.key] else { return }
            Task { await browser.showOnly(pane, id: id) }
        case .playlist:
            guard case .playlist(let id) = BrowserSource(text: item.key),
                browser.playlists.contains(where: { $0.id == id })
            else { return }
            browser.show(.playlist(id))
        case .track:
            // "track:<row>:<id>": the row, if it still shows that track, or on the timeline
            // that play.
            let parts = item.key.split(separator: ":")
            guard parts.count == 3, let row = Int(parts[1]), let id = Int64(parts[2]),
                browser.rowID(at: row) == id
            else { return }
            browser.showRow(row)
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

/// The palette keys of the library's entries, as both the listing and a play count them. Names
/// rather than IDs, so frecency survives a rebuilt index (ADR 0016). Genres and artists are
/// unique by name; an album is unique by its title and artist.
enum LibraryKey {
    /// By ID, which survives a rebuilt index and a rename, since playlists live with the stats;
    /// spelled as the state file saves the playlist as a source.
    static func playlist(_ id: Int64) -> String { BrowserSource.playlist(id).text }
    static func genre(_ name: String) -> String { "genre:\(name)" }
    static func artist(_ name: String) -> String { "artist:\(name)" }
    /// The title and artist apart by a unit separator, a control character tags don't use.
    static func album(_ title: String, by artist: String?) -> String {
        "album:\(title)\u{1F}\(artist ?? "")"
    }
}

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
    [PaletteItem], [String: (BrowserModel.Pane, Int64)]
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
