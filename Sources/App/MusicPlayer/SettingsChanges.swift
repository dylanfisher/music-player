import AppKit
import Commands
import Library
import LibraryBrowser
import Settings
import SettingsWindow
import UniformTypeIdentifiers

/// How the app follows the config file: setting commands, live changes, the banner, and the
/// config file's own commands.
extension AppDelegate {
    func keyBindings(_ overrides: ShortcutOverrides) throws -> KeyBindings {
        try KeyBindings(
            AppCommands.all(), overrides: overrides, rules: AppMenus.rules(appName: appName))
    }

    /// A toggle for each Boolean setting and a command for each choice, all through the config
    /// file, plus Settings…, Open Config File and Copy Default Config.
    func registerSettingCommands(_ dispatcher: CommandDispatcher) {
        dispatcher.handle(
            .showSettings, run: { [weak self] in self?.settingsWindowController()?.show() })
        guard let settings else { return }
        for generated in SettingCommand.all(settings.schema) {
            let key = generated.key
            switch generated.action {
            case .toggle:
                dispatcher.handle(
                    generated.command.id,
                    isOn: { [weak settings] in settings?.isOn(key) == true },
                    run: { [weak self] in
                        guard let settings = self?.settings else { return }
                        self?.change(key, to: !settings.isOn(key))
                    })
            case .choose(let raw):
                dispatcher.handle(
                    generated.command.id,
                    isOn: { [weak settings] in settings?.json(forKey: key) as? String == raw },
                    run: { [weak self] in self?.change(key, to: raw) })
            }
        }
        dispatcher.handle(.openConfigFile, run: { [weak self] in self?.openConfigFile() })
        dispatcher.handle(
            .copyDefaultConfig,
            run: { [weak self] in
                guard let text = self?.settings?.defaultText else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            })
    }

    /// Asks over the Settings window, else the main one, whether to rescan now that Separate
    /// Releases differs from what the index was built with (ADR 0143). Rescan Now relaunches,
    /// and the launch builds it the new way; Cancel puts the setting back. Nothing is asked
    /// while another sheet is up there: the next launch asks instead.
    private func askToSeparateReleases(_ settings: ConfigStore<AppSettings>) {
        let on = settings[\.separateReleases]
        let shown = settingsWindow.map(\.window).flatMap { $0.isVisible ? $0 : nil }
        guard let inUse = separatesReleases, SeparateReleasesChange(inUse: inUse).asks(on),
            let over = shown ?? window?.window, over.attachedSheet == nil
        else { return }
        let change = SeparateReleasesChange(inUse: inUse)
        askToRescan(RescanNotice(separatingReleases: on), over: over) { [weak self] rescan in
            guard let self else { return }
            switch change.answer(rescan: rescan, setting: settings[\.separateReleases]) {
            case .relaunch(let value):
                relaunch(
                    adding: rescanConfirmedArguments(value),
                    failing: "The app couldn't open again; open it to rescan the library")
            case .revert:
                do {
                    try settings.set(\.separateReleases, to: inUse)
                } catch {
                    fail("Couldn't turn Separate Releases back", error)
                }
            case .nothing: break
            }
        }
    }

    private func change(_ key: String, to json: Any) {
        do {
            try settings?.set(key: key, json: json)
        } catch {
            fail("Couldn't change \(key)", error)
        }
    }

    /// Makes the file if there is none, then opens it in the app that opens plain text.
    func openConfigFile() {
        guard let settings else { return }
        do {
            try settings.createIfMissing()
        } catch {
            fail("Couldn't create \(settings.fileURL.path)", error)
            return
        }
        guard let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) else {
            NSWorkspace.shared.open(settings.fileURL)
            return
        }
        NSWorkspace.shared.open(
            [settings.fileURL], withApplicationAt: editor, configuration: .init()
        ) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.fail("Couldn't open the config file", error) }
        }
    }

    /// What follows each changed key: the shortcuts, the appearance,
    /// the watched folders and how they're scanned, the Artist pane's grouping, the track table's
    /// look, receiver control, the output, and when a track counts as played.
    func settingsChanged(_ keys: Set<String>) {
        guard let settings else { return }
        let schema = settings.schema
        if keys.contains(ConfigFile.shortcutsKey), let dispatcher {
            do {
                dispatcher.setBindings(try keyBindings(settings.shortcuts))
            } catch {
                fail("Couldn't apply the shortcuts", error)
            }
        }
        if let dispatcher { settingsWindow?.reload(bindings: dispatcher.bindings) }
        if keys.contains(schema.appearance.key) { applyAppearance(settings[\.appearance]) }
        if !keys.isDisjoint(with: [schema.discogsMapping.key, schema.discogsSavedMappings.key]) {
            discogsTagger?.mappingChanged(
                settings[\.discogsMapping], saved: settings[\.discogsSavedMappings])
        }
        let choices = [
            schema.discogsKeepExistingValues.key, schema.discogsSkipVideo.key,
            schema.discogsFillSortArtist.key, schema.discogsArtwork.key,
        ]
        if !keys.isDisjoint(with: choices) {
            discogsTagger?.choicesChanged(taggerChoices(settings))
        }
        // The tagger reads its catalog from one path; the next one shown reads the new one.
        if keys.contains(schema.discogsCatalogPath.key), let tagger = discogsTagger {
            tagger.window?.close()
            discogsTagger = nil
        }
        if !keys.isDisjoint(with: Self.downloadsKeys(schema)) { applyDownloadsSettings() }
        if keys.contains(schema.downloadsStatusStyle.key) {
            downloads.statusStyle = settings[\.downloadsStatusStyle]
        }
        if keys.contains(schema.autoApproveSafeMatches.key) {
            downloads.autoApprove = settings[\.autoApproveSafeMatches]
        }
        let library = [
            schema.watchedFolders.key, schema.networkScanReaders.key,
            schema.pausePollingDuringPlayback.key, schema.syncFolder.key,
            schema.stagingFolder.key, schema.removeMissingTracks.key,
            schema.rescanModifiedFiles.key,
        ]
        if !keys.isDisjoint(with: library) { changedFolders(settings) }
        if keys.contains(schema.groupByAlbumArtist.key), let browser {
            let on = settings[\.groupByAlbumArtist]
            Task { await browser.setGroupByAlbumArtist(on) }
        }
        if keys.contains(schema.separateReleases.key) { askToSeparateReleases(settings) }
        // A file that stops naming the key leaves the columns as they are, as a launch without
        // it keeps the state file's.
        if keys.contains(schema.browserGroupings.key), let browser,
            let groupings = settings.fileValue(\.browserGroupings)
        {
            Task { await browser.setGroupings(groupings) }
        }
        if !keys.isDisjoint(with: TableAppearance.keys) {
            // The glass first: taking it off puts back the lists' rows, which the track table's
            // appearance then sets.
            window?.setGlass(settings[\.glass])
            browser?.setTableAppearance(TableAppearance(settings))
        }
        if !keys.isDisjoint(with: StatusBarLayout.keys) {
            applyStatusBar(StatusBarLayout(settings))
        }
        if !keys.isDisjoint(with: TotalsFormats.keys) {
            browser?.totalsFormats = TotalsFormats(settings)
        }
        if keys.contains(schema.headerStatusLayout.key) {
            applyHeaderStatus(settings[\.headerStatusLayout])
        }
        for item in ToolbarItem.customStatuses {
            guard let setting = item.customStatusSetting,
                keys.contains(schema[keyPath: setting].key)
            else { continue }
            applyCustomStatus(item, settings[setting])
        }
        if keys.contains(schema.windowTitle.key) {
            nowPlaying?.windowTitle = settings[\.windowTitle]
        }
        if keys.contains(schema.headerTitleFormat.key) {
            nowPlaying?.titleFormat = settings[\.headerTitleFormat]
            toolbar?.titleFormat = settings[\.headerTitleFormat]
        }
        if !keys.isDisjoint(with: [schema.receiverEnabled.key, schema.receiverAddress.key]) {
            applyReceiverSetting()
        }
        let output = [schema.outputDeviceUID.key, schema.hogMode.key, schema.digitalVolume.key]
        if !keys.isDisjoint(with: output) {
            outputSettingsChanged(switched: keys.contains(schema.outputDeviceUID.key))
        }
        if keys.contains(schema.outputRenderer.key) { applyRendererSetting() }
        if keys.contains(schema.playedPercent.key) {
            playTracker?.playedFraction = playedFraction(settings)
        }
    }

    /// Lays out the status bar with the playing track's parts.
    func applyStatusBar(_ layout: StatusBarLayout) {
        guard let browser, let nowPlaying else { return }
        nowPlaying.statusBar.apply(layout.style)
        let parts = nowPlaying.statusBar
        browser.setStatusBar(
            layout,
            views: Dictionary(
                uniqueKeysWithValues: StatusPart.allCases.compactMap { part in
                    parts.view(for: part).map { (part, $0) }
                }))
    }

    /// Lays out the toolbar's status, and its drawing in the customization sheet.
    func applyHeaderStatus(_ layout: BarLayout<HeaderPart>) {
        nowPlaying?.header.apply(layout)
        toolbar?.statusLayout = layout
        toolbar?.resizeStatus()
    }

    /// Lays out a Custom Status item, sizes it again and updates its drawing.
    func applyCustomStatus(_ item: ToolbarItem, _ layout: BarLayout<HeaderPart>) {
        guard let index = ToolbarItem.customStatuses.firstIndex(of: item) else {
            preconditionFailure("\(item) isn't a Custom Status item")
        }
        nowPlaying?.customStatuses[index].apply(layout)
        toolbar?.customStatusLayouts[item] = layout
        toolbar?.resizeStatus()
    }

    /// The Settings window, made on first use.
    func settingsWindowController() -> SettingsWindowController? {
        if let settingsWindow { return settingsWindow }
        guard let settings, let dispatcher else { return nil }
        let value: (String) -> Any? = { [weak settings] in settings?.json(forKey: $0) }
        let set: (String, Any) throws -> Void = { [weak settings] key, json in
            try settings?.set(key: key, json: json)
        }
        let general = GeneralModel(
            settings: settings.schema.settings,
            searcherInstalled: NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: FileViewer.searcher.bundleID) != nil,
            value: value, set: set, isBlocked: { [weak settings] in settings?.blocked ?? false })
        let shortcuts = ShortcutsModel(bindings: dispatcher.bindings, appName: appName) {
            [weak self, weak settings, weak dispatcher] changes in
            do {
                try settings?.setShortcuts(
                    Dictionary(uniqueKeysWithValues: changes.map { ($0.key.rawValue, $0.value) }))
            } catch {
                // The pane shows the shortcuts in effect again.
                if let dispatcher { self?.settingsWindow?.reload(bindings: dispatcher.bindings) }
                self?.fail("Couldn't change the shortcuts", error)
            }
        }
        let controller = SettingsWindowController(
            general: general, shortcuts: shortcuts, configPath: settings.fileURL.path,
            actions: SettingsActions(
                openConfigFile: { [weak self] in self?.openConfigFile() },
                revealConfigFile: { [weak settings] in
                    guard let url = settings?.fileURL else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                },
                copyDefaultConfig: { [weak dispatcher] in dispatcher?.run(.copyDefaultConfig) },
                chooseSyncFolder: { [weak self] in self?.chooseSyncFolder() },
                openSyncFolder: { [weak self] in
                    guard let window = self?.settingsWindow?.window else { return }
                    self?.openSyncFolder(over: window)
                },
                chooseStagingFolder: { [weak self] in self?.chooseStagingFolder() },
                addFolder: { [weak self] in
                    guard let window = self?.settingsWindow?.window else { return }
                    self?.addFolder(over: window)
                },
                removeFolder: { [weak self] position in
                    guard let window = self?.settingsWindow?.window else { return }
                    self?.confirmRemovingFolder(at: position, over: window)
                },
                rescanNow: { [weak dispatcher] in
                    if dispatcher?.run(.rescanNow) != true { NSSound.beep() }
                },
                rescanFolders: { [weak self] in self?.rescanFolders(at: $0) },
                outputs: { [weak self] in self?.outputOptionsNow() ?? [] },
                searchOutputs: { [weak self] in self?.searchOutputs() },
                chooseOutput: { [weak self] in self?.chooseOutput($0) },
                showHealth: { [weak self, weak dispatcher] in
                    // A button that says Show doesn't hide it: with it showing, the main window
                    // comes forward.
                    if self?.browser?.showsHealth == true {
                        self?.window?.window.makeKeyAndOrderFront(nil)
                    } else if dispatcher?.run(.checkHealth) != true {
                        NSSound.beep()
                    }
                },
                libraryDatabase: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await libraryDatabase()
                },
                revealIndex: { [paths] in
                    NSWorkspace.shared.activateFileViewerSelecting([
                        libraryFileURL(in: paths.dataDirectory)
                    ])
                },
                backUpNow: { [weak self] in await self?.backUpNow() },
                restoreSnapshot: { [weak self] snapshot in
                    guard let window = self?.settingsWindow?.window else { return }
                    self?.confirmRestoring(snapshot, over: window)
                }), value: value, set: set)
        settingsWindow = controller
        return controller
    }

    func showConfigProblems() {
        guard let settings else { return }
        banner.show(
            problems: settings.problems, writeFailure: settings.writeFailure,
            path: settings.fileURL.path, unwatched: unwatchedNotice(settings),
            stateFailure: saver?.failure,
            stateDiscarded: state?.discarded ?? [], configEdits: settings.edits)
    }
}

/// The share of a track that has to play for it to count, as the tracker takes it.
@MainActor
func playedFraction(_ settings: ConfigStore<AppSettings>) -> Double {
    Double(settings[\.playedPercent]) / 100
}

/// What the sync folder's Open button says when it can't open the folder: a title and the
/// detail under it. `share` is the share the folder is on, or its path when it's on none.
func syncFolderProblem(_ place: SyncFolderPlace, share: String) -> (String, String) {
    switch place {
    case .found(let path):
        (
            "The sync folder is missing: \(path)",
            "It was moved or deleted, or its disk isn't connected. Choose it again with Change…."
        )
    case .unmounted:
        (
            "The sync folder's share isn't mounted",
            "Connect to \(share) in Finder, then open it again."
        )
    case .ambiguous(let mountPoints):
        (
            "The sync folder's share is mounted more than once",
            "\(share) could be the share at any of \(mountPoints.joined(separator: ", ")). Eject"
                + " the ones that aren't it, then open it again."
        )
    }
}

/// The panel that asks for the sync folder, open at `path`, or where macOS opens one when it's
/// nil.
@MainActor
func syncFolderPanel(at path: String?) -> NSOpenPanel {
    folderPanel(
        at: path, prompt: "Sync Here",
        message: "Choose a folder outside your music for the Macs that play this library to"
            + " share their stats through. The app writes only its own log there.")
}

/// The panel that asks for the staging folder.
@MainActor
func stagingFolderPanel() -> NSOpenPanel {
    folderPanel(
        at: nil, prompt: "Stage Here",
        message: "Choose the folder music-recommender puts downloads in for review, outside"
            + " your music, on the same share as the library folder.")
}

/// A panel that asks for one folder, which it can create, open at `path`, or where macOS opens
/// one when it's nil.
@MainActor
private func folderPanel(at path: String?, prompt: String, message: String) -> NSOpenPanel {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = prompt
    panel.message = message
    panel.directoryURL = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    return panel
}

/// Sets the whole app's appearance; nil follows the system as it changes.
@MainActor
func applyAppearance(_ appearance: Appearance) {
    NSApp.appearance =
        switch appearance {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
}
