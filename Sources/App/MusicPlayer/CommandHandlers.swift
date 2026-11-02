import AppKit
import Commands
import LibraryBrowser
import Log
import Playback
import Settings

private let logger = moduleLogger()

/// What each command does in the window: the wiring from command IDs to the features, the
/// engine and the settings. Each handler says when its command is on.
extension AppDelegate {
    func registerCommands(_ dispatcher: CommandDispatcher) {
        registerListCommands(dispatcher)
        registerViewCommands(dispatcher)
        registerPlaybackCommands(dispatcher)
        registerPlaylistCommands(dispatcher)
        registerTagCommands(dispatcher)
        registerReceiverCommands(dispatcher)
        dispatcher.handle(.addFolder, enabled: hasWindow) { [weak self] in
            guard let window = self?.window?.window else { return }
            self?.addFolder(over: window)
        }
        dispatcher.handle(.showWatchedFolders) { [weak self] in
            self?.settingsWindowController()?.show(.folders)
        }
        dispatcher.handle(.checkHealth, enabled: hasWindow) { [weak self] in
            self?.browser?.checkHealth()
        }
        dispatcher.handle(
            .rescanNow, enabled: { [weak self] in self?.watcher != nil },
            run: { [weak self] in self?.watcher?.rescanNow() })
        dispatcher.handle(.resolveLostStats, enabled: hasWindow) { [weak self] in
            guard let window = self?.window?.window else { return }
            self?.browser?.resolveLostStats(over: window)
        }
    }

    /// Whether the main window is open, for the commands that need it.
    var hasWindow: () -> Bool { { [weak self] in self?.window != nil } }

    /// Whether the track table has a selection, for the commands that act on it.
    var hasSelectedTracks: () -> Bool {
        { [weak self] in self?.browser?.hasSelectedTracks == true }
    }

    private func registerListCommands(_ dispatcher: CommandDispatcher) {
        for (id, move) in RowMove.commands {
            dispatcher.handle(id, enabled: hasWindow) { [weak self] in
                self?.moveSelection(move.move, extending: move.extending)
            }
        }
        dispatcher.handle(.selectAll, enabled: hasWindow) { [weak self] in
            guard let self else { return }
            if self.window?.window.firstResponder === self.queue?.list {
                self.queue?.selectAll()
            } else {
                self.browser?.selectAllTracks()
            }
        }
        dispatcher.handle(.revealInFinder, enabled: hasSelectedTracks) { [weak self] in
            self?.withSelectedPaths(revealInFinder)
        }
        dispatcher.handle(.copyPath, enabled: hasSelectedTracks) { [weak self] in
            self?.withSelectedPaths { paths in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
            }
        }
        let removal = { [weak self] () -> Removal? in
            guard let self, let window = self.window?.window else { return nil }
            return removalTarget(
                queueFocused: window.firstResponder === self.queue?.list,
                queueHasSelection: self.queue?.hasSelection == true,
                tracksFocused: self.browser?.tracksHaveFocus == true,
                canRemoveFromPlaylist: self.browser?.canRemoveFromPlaylist == true)
        }
        dispatcher.handle(
            .removeFromQueue, enabled: { removal() != nil },
            run: { [weak self] in
                switch removal() {
                case .queue: self?.queue?.removeSelection()
                case .playlist: self?.browser?.removeSelectionFromPlaylist()
                case nil: break
                }
            })
    }

    private func registerViewCommands(_ dispatcher: CommandDispatcher) {
        dispatcher.handle(.find, enabled: hasWindow) { [weak self] in self?.browser?.focusSearch() }
        let sorts: [(CommandID, TrackColumn)] = [
            (.sortByTitle, .title), (.sortByArtist, .artist), (.sortByAlbum, .album),
            (.sortByDateAdded, .dateAdded),
        ]
        let canSort = { [weak self] in self?.browser?.canSort == true }
        for (id, column) in sorts {
            dispatcher.handle(
                id, enabled: canSort,
                isOn: { [weak self] in self?.browser?.sortColumn == column },
                run: { [weak self] in self?.browser?.sort(by: column) })
        }
        dispatcher.handle(.reverseSort, enabled: canSort) { [weak self] in
            self?.browser?.reverseSort()
        }
        dispatcher.handle(
            .toggleSidebar, enabled: hasWindow,
            isOn: { [weak self] in self?.window?.isSidebarVisible == true },
            run: { [weak self] in self?.window?.toggleSidebar() })
        dispatcher.handle(.focusSidebar, enabled: hasWindow) { [weak self] in
            self?.window?.showSidebar()
            self?.browser?.focusSidebar()
        }
        dispatcher.handle(
            .toggleStatusBar, enabled: hasWindow,
            isOn: { [weak self] in self?.browser?.isStatusBarVisible == true },
            run: { [weak self] in
                guard let browser = self?.browser else { return }
                browser.toggleStatusBar()
                self?.saver?.set(\.statusBarVisible, browser.isStatusBarVisible)
            })
        dispatcher.handle(
            .toggleBrowser, enabled: hasWindow,
            isOn: { [weak self] in self?.browser?.isBrowserVisible == true },
            run: { [weak self] in
                guard let browser = self?.browser else { return }
                browser.toggleBrowser()
                self?.saver?.set(\.browserVisible, browser.isBrowserVisible)
            })
        dispatcher.handle(
            .toggleQueue, enabled: hasWindow,
            isOn: { [weak self] in self?.window?.isQueueVisible == true },
            run: { [weak self] in self?.window?.toggleQueue() })
        dispatcher.handle(
            .toggleSignalPath, enabled: hasWindow,
            isOn: { [weak self] in self?.window?.isSignalPathVisible == true },
            run: { [weak self] in self?.window?.toggleSignalPath() })
        dispatcher.handle(
            .showCurrentTrack, enabled: { [weak self] in self?.currentTrackPath != nil },
            run: { [weak self] in
                guard let self, let path = self.currentTrackPath, let browser = self.browser else {
                    return
                }
                Task { await browser.reveal(path: path) }
            })
        dispatcher.handle(
            .back, enabled: { [weak self] in self?.browser?.canGoBack == true },
            run: {
                [weak self] in self?.browser?.back()
            })
        dispatcher.handle(
            .forward, enabled: { [weak self] in self?.browser?.canGoForward == true },
            run: { [weak self] in self?.browser?.forward() })
        dispatcher.handle(.focusNextPane, enabled: hasWindow) { [weak self] in
            self?.browser?.focusPane(forward: true)
        }
        dispatcher.handle(.focusPreviousPane, enabled: hasWindow) { [weak self] in
            self?.browser?.focusPane(forward: false)
        }
        dispatcher.handle(.focusNextArea, enabled: hasWindow) { [weak self] in
            self?.focusNextArea()
        }
    }

    private func registerPlaybackCommands(_ dispatcher: CommandDispatcher) {
        let hasEngine = { [weak self] in self?.engine != nil }
        func engineCommand(
            _ id: CommandID, isOn: ((PlaybackState) -> Bool)? = nil,
            run: @escaping @Sendable (PlaybackEngine) async -> Void
        ) {
            dispatcher.handle(
                id, enabled: hasEngine,
                isOn: isOn.map { isOn in { [weak self] in self.map { isOn($0.playback) } ?? false }
                },
                run: { [weak self] in
                    guard let engine = self?.engine else { return }
                    Task { await run(engine) }
                })
        }
        engineCommand(.playPause) { await $0.togglePause() }
        // Absolute, so a second press of either does nothing whatever the menus last saw.
        engineCommand(.play) { await $0.play() }
        engineCommand(.pause) { await $0.pause() }
        engineCommand(.stop) { await $0.stop() }
        engineCommand(.nextTrack) { await $0.next() }
        engineCommand(.previousTrack) { await $0.previous() }
        engineCommand(.seekForward) { await seek($0, by: seekStepSeconds) }
        engineCommand(.seekBack) { await seek($0, by: -seekStepSeconds) }
        engineCommand(.shuffle, isOn: \.shuffle) { await $0.setShuffle(!(await $0.state.shuffle)) }
        let repeats: [(CommandID, RepeatMode)] = [
            (.repeatOff, .off), (.repeatAll, .all), (.repeatOne, .one),
        ]
        for (id, mode) in repeats {
            engineCommand(id, isOn: { $0.repeatMode == mode }, run: { await $0.setRepeat(mode) })
        }
        let playsFromList = { [weak self] in self?.engine != nil && self?.window != nil }
        dispatcher.handle(.playSelection, enabled: playsFromList) { [weak self] in
            guard let self else { return }
            if self.window?.window.firstResponder === self.queue?.list {
                self.queue?.playSelection()
            } else {
                self.browser?.playSelection()
            }
        }
        dispatcher.handle(.playNext, enabled: playsFromList) { [weak self] in
            self?.browser?.playSelectionNext()
        }
        let hasVolume = { [weak self] in self?.engine != nil && self?.digitalVolume == true }
        dispatcher.handle(.volumeUp, enabled: hasVolume) { [weak self] in
            self?.changeVolume(by: volumeStepDecibels)
        }
        dispatcher.handle(.volumeDown, enabled: hasVolume) { [weak self] in
            self?.changeVolume(by: -volumeStepDecibels)
        }
    }

    // MARK: Helpers

    private func moveSelection(_ move: RowMove, extending: Bool) {
        if window?.window.firstResponder === queue?.list {
            queue?.move(move, extending: extending)
        } else if browser?.moveSelection(move, extending: extending) != true {
            // Nothing in the window has a list's keys, as after the search field: the table
            // takes them.
            browser?.focusTracks()
            _ = browser?.moveSelection(move, extending: extending)
        }
    }

    func withSelectedPaths(_ use: @escaping ([String]) -> Void) {
        guard let browser else { return }
        Task {
            do {
                use(try await browser.selectedPaths())
            } catch {
                browser.reportCommand("couldn't read the selected tracks", error)
            }
        }
    }

    /// Tab: the sidebar, the panes, the track table, then the queue when it shows.
    private func focusNextArea() {
        guard let browser, let window = window?.window else { return }
        var areas = browser.focusAreas
        if self.window?.isQueueVisible == true, let queue { areas.append(queue.list) }
        if self.window?.isSidebarVisible != true { areas.removeFirst() }
        let current = areas.firstIndex { $0 === window.firstResponder }
        let next = current.map { (areas.index(after: $0)) % areas.count } ?? 0
        window.makeFirstResponder(areas[next])
    }

    private func changeVolume(by step: Double) {
        guard let engine else { return }
        let decibels = min(0, volumeDecibels + step)
        volumeDecibels = decibels
        saveVolume(decibels)
        Task {
            do {
                try await engine.setVolume(pow(10, decibels / 20))
            } catch {
                logger.error("couldn't set the volume: \(error)")
            }
        }
    }
}

private func seek(_ engine: PlaybackEngine, by seconds: Double) async {
    guard let position = await engine.position() else { return }
    await engine.seek(toSeconds: max(0, position + seconds))
}

/// What Remove from Queue or Playlist takes from.
enum Removal: Equatable {
    case queue, playlist
}

/// The list with the keys decides: the queue's selection when the queue has them, the selected
/// tracks of a manual playlist when the track table has them, nothing anywhere else.
func removalTarget(
    queueFocused: Bool, queueHasSelection: Bool, tracksFocused: Bool, canRemoveFromPlaylist: Bool
) -> Removal? {
    if queueFocused { return queueHasSelection ? .queue : nil }
    if tracksFocused, canRemoveFromPlaylist { return .playlist }
    return nil
}
