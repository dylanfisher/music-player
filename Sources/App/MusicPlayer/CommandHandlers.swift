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
        dispatcher.handle(
            .checkHealth, enabled: hasWindow,
            isOn: { [weak self] in self?.browser?.showsHealth == true },
            run: { [weak self] in
                guard let self, let browser else { return }
                // From Settings too, which is in front then.
                window?.window.makeKeyAndOrderFront(nil)
                let path = currentTrackPath
                Task { await browser.toggleHealth(playingPath: path) }
            })
        dispatcher.handle(.showStats, enabled: hasWindow) { [weak self] in
            self?.window?.window.makeKeyAndOrderFront(nil)
            self?.browser?.showStats()
        }
        dispatcher.handle(.showYearInReview, enabled: hasWindow) { [weak self] in
            self?.browser?.showYearInReview()
        }
        dispatcher.handle(
            .rescanNow, enabled: { [weak self] in self?.watcher != nil },
            run: { [weak self] in self?.watcher?.rescanNow() })
        dispatcher.handle(.resolveLostStats, enabled: hasWindow) { [weak self] in
            guard let window = self?.window?.window else { return }
            self?.browser?.resolveLostStats(over: window)
        }
        dispatcher.handle(.restoreRemoved, enabled: hasWindow) { [weak self] in
            guard let window = self?.window?.window else { return }
            self?.browser?.restoreRemoved(over: window)
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
            self?.withSelectedPaths { self?.revealTracks($0) }
        }
        dispatcher.handle(
            .removeTracks, enabled: { [weak self] in self?.browser?.canRemoveSelection == true },
            run: { [weak self] in
                guard let window = self?.window?.window else { return }
                self?.browser?.removeSelection(over: window)
            })
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
        dispatcher.handle(
            .find, enabled: { [weak self] in self?.browser?.isSearchShown == true },
            run: { [weak self] in self?.browser?.focusSearch() })
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
        dispatcher.handle(
            .toggleToolbar, enabled: hasWindow,
            isOn: { [weak self] in self?.window?.isToolbarVisible == true },
            run: { [weak self] in self?.window?.toggleToolbar() })
        dispatcher.handle(
            .distractionFree, enabled: hasWindow,
            isOn: { [weak self] in self?.window?.isDistractionFree == true },
            run: { [weak self] in self?.window?.toggleDistractionFree() })
        dispatcher.handle(.focusSidebar, enabled: hasWindow) { [weak self] in
            self?.window?.showSidebar()
            self?.browser?.focusSidebar()
        }
        dispatcher.handle(
            .toggleStatusBar, enabled: hasWindow,
            isOn: { [weak self] in self?.browser?.isStatusBarVisible == true },
            run: { [weak self] in
                self?.window?.toggleStatusBar()
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
            .showCurrentTrack,
            enabled: { [weak self] in
                guard let self else { return false }
                return browser?.canShowCurrentTrack(playingPath: currentTrackPath) == true
            },
            run: { [weak self] in
                guard let self, let browser else { return }
                let path = currentTrackPath
                Task { await browser.showCurrentTrack(playingPath: path) }
            })
        dispatcher.handle(
            .showSelectedTrack, enabled: { [weak self] in self?.browser?.hasSelection == true },
            run: { [weak self] in self?.browser?.showSelectedTrack() })
        dispatcher.handle(
            .showAllTracks, enabled: { [weak self] in self?.browser?.showsAllMusic == false },
            run: { [weak self] in self?.browser?.showAll() })
        dispatcher.handle(.scrollUp, enabled: hasWindow) { [weak self] in
            self?.browser?.scrollTracks(byRows: -1)
        }
        dispatcher.handle(.scrollDown, enabled: hasWindow) { [weak self] in
            self?.browser?.scrollTracks(byRows: 1)
        }
        dispatcher.handle(
            .back, enabled: { [weak self] in self?.browser?.canGoBack == true },
            run: {
                [weak self] in self?.browser?.back()
            })
        dispatcher.handle(
            .forward, enabled: { [weak self] in self?.browser?.canGoForward == true },
            run: { [weak self] in self?.browser?.forward() })
        dispatcher.handle(
            .undoSelection, enabled: { [weak self] in self?.browser?.canUndoSelection == true },
            run: { [weak self] in self?.browser?.undoSelection() })
        dispatcher.handle(
            .redoSelection, enabled: { [weak self] in self?.browser?.canRedoSelection == true },
            run: { [weak self] in self?.browser?.redoSelection() })
        dispatcher.handle(.focusNextPane, enabled: hasWindow) { [weak self] in
            self?.browser?.focusPane(forward: true)
        }
        dispatcher.handle(.focusPreviousPane, enabled: hasWindow) { [weak self] in
            self?.browser?.focusPane(forward: false)
        }
        dispatcher.handle(.focusNextArea, enabled: hasWindow) { [weak self] in
            self?.window?.moveFocus(forward: true)
        }
        dispatcher.handle(.focusPreviousArea, enabled: hasWindow) { [weak self] in
            self?.window?.moveFocus(forward: false)
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
        engineCommand(.seekForwardPercent) { await seek($0, byShare: seekStepShare) }
        engineCommand(.seekBackPercent) { await seek($0, byShare: -seekStepShare) }
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
        dispatcher.handle(
            .addToQueue,
            enabled: { [weak self] in self?.engine != nil && self?.hasSelectedTracks() == true },
            run: { [weak self] in self?.browser?.addSelectionToQueue() })
        let hasVolume = { [weak self] in self?.canSetVolume == true }
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

    /// Shows the files at `paths` in the file viewer the settings pick.
    func revealTracks(_ paths: [String]) {
        guard let settings else { return }
        reveal(paths, in: settings[\.fileViewer])
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

    /// The digital volume is the device's; a renderer has none the app sets (ADR 0041).
    var canSetVolume: Bool { engine != nil && digitalVolume && rendererOutput == nil }

    private func changeVolume(by step: Double) {
        setVolume(min(0, volumeDecibels + step), saving: true)
    }

    /// Sets the digital volume to `decibels`, saved in the device's profile when `saving`; the
    /// toolbar's slider saves only once a drag ends.
    func setVolume(_ decibels: Double, saving: Bool) {
        guard let engine else { return }
        volumeDecibels = decibels
        if saving { saveVolume(decibels) }
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

/// The share of the track's duration Seek Forward and Back 5% or 30 s move by.
let seekStepShare = Double(AppCommands.seekStepPercent) / 100

/// Seeks by `share` of the playing track's duration, or at least the minimum step.
private func seek(_ engine: PlaybackEngine, byShare share: Double) async {
    await seek(engine, by: seekSeconds(share, ofDuration: await engine.state.durationSeconds))
}

/// How far a seek by `share` of a track `durationSeconds` long moves, in the share's
/// direction: `AppCommands.seekStepMinimumSeconds` when that's longer, or when the duration is
/// unknown.
func seekSeconds(_ share: Double, ofDuration durationSeconds: Double?) -> Double {
    let minimum = Double(AppCommands.seekStepMinimumSeconds)
    let step = max(minimum, abs(share) * (durationSeconds ?? 0))
    return share < 0 ? -step : step
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
