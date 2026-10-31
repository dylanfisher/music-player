import AppKit
import Commands
import Library
import Playback
import PlaylistEditor

/// What a new playlist is called until the user names it.
let untitledPlaylist = "Untitled Playlist"
let untitledSmartPlaylist = "Untitled Smart Playlist"

/// The playlist and rating commands, and the dialogs they open. Every edit goes through the
/// browser, which writes it to the library and refreshes what it changed.
extension AppDelegate {
    func registerPlaylistCommands(_ dispatcher: CommandDispatcher) {
        dispatcher.handle(.newPlaylist, enabled: hasWindow) { [weak self] in
            self?.newPlaylist(withSelection: false)
        }
        dispatcher.handle(.newPlaylistFromSelection, enabled: hasSelectedTracks) { [weak self] in
            self?.newPlaylist(withSelection: true)
        }
        dispatcher.handle(.newSmartPlaylist, enabled: hasWindow) { [weak self] in
            self?.editRules(of: nil)
        }
        let shownSmart = { [weak self] in self?.browser?.shownPlaylist?.isManual == false }
        dispatcher.handle(.editSmartPlaylist, enabled: shownSmart) { [weak self] in
            self?.editRules(of: self?.browser?.shownPlaylist)
        }
        let shown = { [weak self] in self?.browser?.shownPlaylist != nil }
        dispatcher.handle(.renamePlaylist, enabled: shown) { [weak self] in
            self?.renameShownPlaylist()
        }
        dispatcher.handle(.deletePlaylist, enabled: shown) { [weak self] in
            self?.confirmDeletingShownPlaylist()
        }
        let canAdd = { [weak self] in
            self?.hasSelectedTracks() == true
                && self?.browser?.playlists.contains(where: \.isManual) == true
        }
        dispatcher.handle(.addToPlaylist, enabled: canAdd) { [weak self] in
            self?.chooseManualPlaylist()
        }
        for (stars, id) in CommandID.rate.enumerated() {
            dispatcher.handle(id, enabled: hasSelectedTracks) { [weak self] in
                self?.browser?.rateSelection(stars)
            }
        }
    }

    private func newPlaylist(withSelection: Bool) {
        askForName(
            "New Playlist", button: "Create", initial: untitledPlaylist
        ) { [weak self] name in
            self?.browser?.createPlaylist(named: name, rules: nil, withSelection: withSelection)
        }
    }

    private func renameShownPlaylist() {
        guard let playlist = browser?.shownPlaylist else { return }
        askForName("Rename Playlist", button: "Rename", initial: playlist.name) {
            [weak self] name in self?.browser?.renamePlaylist(playlist.id, to: name)
        }
    }

    private func confirmDeletingShownPlaylist() {
        guard let playlist = browser?.shownPlaylist, let window = window?.window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the playlist “\(playlist.name)”?"
        alert.informativeText =
            "Its tracks stay in the library, and their files aren't touched."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.browser?.deletePlaylist(playlist.id)
        }
    }

    /// Add to Playlist…: a sheet with the manual playlists in a pop-up button.
    private func chooseManualPlaylist() {
        guard let browser, let window = window?.window else { return }
        let playlists = browser.playlists.filter(\.isManual)
        guard !playlists.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Add the selected tracks to a playlist"
        let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        for playlist in playlists { menu.addItem(withTitle: playlist.name) }
        alert.accessoryView = menu
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak browser] response in
            guard response == .alertFirstButtonReturn else { return }
            browser?.addSelection(to: playlists[menu.indexOfSelectedItem].id)
        }
    }

    /// Opens the rule editor on `playlist`'s rules, or on a new smart playlist for nil.
    func editRules(of playlist: Playlist?) {
        guard let window = window?.window else { return }
        let rules: SmartRules? =
            switch playlist?.kind {
            case .smart(let rules): rules
            case .manual, .unreadable, nil: nil
            }
        let sheet = RuleEditorSheet(
            draft: RuleDraft(name: playlist?.name ?? untitledSmartPlaylist, rules: rules),
            saveTitle: playlist == nil ? "Create" : "Save")
        sheet.saved = { [weak self] name, rules in
            guard let browser = self?.browser else { return }
            if let playlist {
                if name != playlist.name { browser.renamePlaylist(playlist.id, to: name) }
                browser.setRules(rules, of: playlist.id)
            } else {
                browser.createPlaylist(named: name, rules: rules, withSelection: false)
            }
            self?.ruleEditor = nil
        }
        ruleEditor = sheet
        sheet.begin(over: window)
    }

    /// A sheet asking for a playlist's name. An empty name beeps and changes nothing.
    private func askForName(
        _ title: String, button: String, initial: String,
        _ done: @escaping (String) -> Void
    ) {
        guard let window = window?.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                NSSound.beep()
                return
            }
            done(name)
        }
    }

    // MARK: Counting plays

    /// Counts plays and skips from each engine update, and wakes once when the current track
    /// would count.
    func countPlays(_ update: PlaybackUpdate) {
        record(playCounter.handle(update, at: Date()))
        playTick?.cancel()
        guard let deadline = playCounter.deadline else { return }
        let waitNanoseconds = UInt64(max(0, deadline.timeIntervalSinceNow) * 1e9)
        playTick = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: waitNanoseconds)
            } catch {
                // Cancelled: a newer update scheduled its own tick.
                return
            }
            guard let self else { return }
            self.record(self.playCounter.tick(at: Date()))
        }
    }

    private func record(_ events: [PlayCounter.Event]) {
        for event in events {
            switch event {
            case .played(let url): browser?.recordPlay(url.path, at: Date().timeIntervalSince1970)
            case .skipped(let url): browser?.recordSkip(url.path)
            }
        }
    }
}
