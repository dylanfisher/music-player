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
        dispatcher.handle(
            .showPalette, enabled: { [weak self] in self?.window != nil },
            run: { [weak self] in
                self?.showPalette(.commands)
            })
        dispatcher.handle(
            .goToItem, enabled: { [weak self] in self?.window != nil },
            run: { [weak self] in
                self?.showPalette(.goToItem)
            })
    }

    private func showPalette(_ mode: PaletteMode) {
        guard let palette, let window = window?.window, let browser, let state else { return }
        if palette.mode == mode {
            palette.close()
            return
        }
        switch mode {
        case .commands:
            palette.show(
                .commands, items: commandItems(), over: window, place: state[\.palettePlace])
            Task {
                do {
                    let entries = try await browser.allEntries()
                    var items: [PaletteItem] = []
                    paletteEntries = [:]
                    for (pane, entry) in entries {
                        let key = "\(pane.title.lowercased()):\(entry.name)"
                        guard paletteEntries[key] == nil else { continue }
                        paletteEntries[key] = (pane, entry.id)
                        items.append(
                            PaletteItem(
                                kind: kind(pane), key: key, title: entry.name, detail: pane.title))
                    }
                    guard palette.mode == .commands else { return }
                    palette.append(items)
                } catch {
                    logger.error("couldn't list the library for the palette: \(error)")
                }
            }
        case .goToItem:
            palette.show(.goToItem, items: [], over: window, place: state[\.palettePlace])
            Task {
                do {
                    guard let names = try await browser.trackNames() else { return }
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
                    guard palette.mode == .goToItem else { return }
                    palette.append(items)
                } catch {
                    logger.error("couldn't list the tracks for Go to Item: \(error)")
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
        return bindings.registry.commands.compactMap { command in
            guard RowMove.commands[command.id] == nil, command.id != .showPalette else {
                return nil
            }
            var title = command.title
            if let key = toggles[command.id] {
                title = SettingCommand.paletteTitle(
                    title, isOn: settings.json(forKey: key) as? Bool == true)
            }
            return PaletteItem(
                kind: .command, key: "command:\(command.id)", title: title,
                detail: section[command.id],
                chord: command.chords.first?.symbols, isEnabled: dispatcher.isEnabled(command.id))
        }
    }

    private func kind(_ pane: BrowserModel.Pane) -> PaletteItem.Kind {
        switch pane {
        case .genre: .genre
        case .artist: .artist
        case .album: .album
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
        case .track:
            // "track:<row>:<id>": the row, if it still shows that track.
            let parts = item.key.split(separator: ":")
            guard parts.count == 3, let row = Int(parts[1]), let id = Int64(parts[2]),
                browser.trackID(at: row) == id
            else { return }
            browser.showRow(row)
        case .setting:
            break
        }
    }

    /// A play counts toward its artist's, album's and genre's frecency.
    func countPlay(_ path: String) {
        guard let palette, let trackLookup else { return }
        do {
            guard let track = try trackLookup(path) else { return }
            for key in [
                track.artist.map { "artist:\($0)" }, track.album.map { "album:\($0)" },
                track.genre.map { "genre:\($0)" },
            ].compactMap({ $0 }) {
                palette.model.record(key)
            }
            saver?.set(\.paletteVisits, palette.model.frecency.log)
        } catch {
            logger.error("couldn't count the play of \(path): \(error)")
        }
    }
}
