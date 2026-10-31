import Commands
import Settings

/// The shortcut rules the config file is checked against: the registry's IDs and the menus'
/// reserved and fixed chords.
func shortcutCheck() throws -> ShortcutCheck {
    let bindings = try KeyBindings(
        AppCommands.all(), overrides: [:], rules: AppMenus.rules(appName: appName))
    return { id, position, slot in bindings.problem(id: id, position: position, slot: slot) }
}

/// The config file for a command-line mode, which fails on any problem in it.
@MainActor
func readConfig(_ paths: AppPaths) throws -> ConfigStore<AppSettings> {
    try ConfigStore.strict(AppSettings(), fileURL: paths.configFile, check: try shortcutCheck())
}
