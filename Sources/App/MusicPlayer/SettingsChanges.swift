import AppKit
import Commands
import Settings
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
                    isOn: { [weak settings] in settings?.json(forKey: key) as? Bool == true },
                    run: { [weak self] in
                        guard let settings = self?.settings else { return }
                        self?.change(key, to: !(settings.json(forKey: key) as? Bool ?? false))
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
    /// how they're scanned, and the output.
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
        if keys.contains(schema.appearance.key) { applyAppearance(settings[\.appearance]) }
        let library = [
            schema.watchedFolders.key, schema.networkScanReaders.key,
            schema.pausePollingDuringPlayback.key,
        ]
        if !keys.isDisjoint(with: library) { changedFolders(settings[\.watchedFolders], settings) }
        let output = [schema.outputDeviceUID.key, schema.hogMode.key, schema.digitalVolume.key]
        if !keys.isDisjoint(with: output) { reopenOutput() }
    }

    func showConfigProblems() {
        guard let settings else { return }
        banner.show(
            problems: settings.problems, writeFailure: settings.writeFailure,
            path: settings.fileURL.path)
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
