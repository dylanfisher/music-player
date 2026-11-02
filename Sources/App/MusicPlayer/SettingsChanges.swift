import AppKit
import Commands
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
    /// file, plus Open Config File and Copy Default Config.
    func registerSettingCommands(_ dispatcher: CommandDispatcher) {
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

    /// What follows each changed key: the shortcuts, the appearance, the watched folders and
    /// how they're scanned, the Artist pane's grouping, receiver control, and the output.
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
        let library = [
            schema.watchedFolders.key, schema.networkScanReaders.key,
            schema.pausePollingDuringPlayback.key, schema.syncFolder.key,
        ]
        if !keys.isDisjoint(with: library) { changedFolders(settings[\.watchedFolders], settings) }
        if keys.contains(schema.groupByAlbumArtist.key), let browser {
            let on = settings[\.groupByAlbumArtist]
            Task { await browser.setGroupByAlbumArtist(on) }
        }
        if !keys.isDisjoint(with: [schema.receiverEnabled.key, schema.receiverAddress.key]) {
            applyReceiverSetting()
        }
        if keys.contains(schema.receiverVolumeKeys.key) { applyVolumeKeys() }
        let output = [schema.outputDeviceUID.key, schema.hogMode.key, schema.digitalVolume.key]
        if !keys.isDisjoint(with: output) {
            outputSettingsChanged(switched: keys.contains(schema.outputDeviceUID.key))
        }
        if keys.contains(schema.outputRenderer.key) { applyRendererSetting() }
    }

    /// The Settings window, made on first use.
    func settingsWindowController() -> SettingsWindowController? {
        if let settingsWindow { return settingsWindow }
        guard let settings, let dispatcher else { return nil }
        let general = GeneralModel(
            settings: settings.schema.settings,
            value: { [weak settings] in settings?.json(forKey: $0) },
            set: { [weak settings] key, json in try settings?.set(key: key, json: json) })
        let shortcuts = ShortcutsModel(bindings: dispatcher.bindings, appName: appName) {
            [weak settings] changes in
            settings?.setShortcuts(
                Dictionary(uniqueKeysWithValues: changes.map { ($0.key.rawValue, $0.value) }))
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
                outputs: { [weak self] in self?.outputOptionsNow() ?? [] },
                searchOutputs: { [weak self] in self?.searchOutputs() },
                chooseOutput: { [weak self] in self?.chooseOutput($0) }))
        settingsWindow = controller
        return controller
    }

    func showConfigProblems() {
        guard let settings else { return }
        banner.show(
            problems: settings.problems, writeFailure: settings.writeFailure,
            path: settings.fileURL.path, stateFailure: saver?.failure,
            stateDiscarded: state?.discardReason)
    }
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
