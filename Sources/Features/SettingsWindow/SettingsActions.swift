/// What the Settings window asks the app to do with the config file and the library.
public struct SettingsActions {
    public var openConfigFile: () -> Void
    public var revealConfigFile: () -> Void
    public var copyDefaultConfig: () -> Void
    /// Asks for a folder and makes it the sync folder.
    public var chooseSyncFolder: () -> Void
    /// Asks for a folder to watch.
    public var addFolder: () -> Void
    /// Asks to stop watching the folder at this position in the setting.
    public var removeFolder: (Int) -> Void
    public var rescanNow: () -> Void

    public init(
        openConfigFile: @escaping () -> Void, revealConfigFile: @escaping () -> Void,
        copyDefaultConfig: @escaping () -> Void, chooseSyncFolder: @escaping () -> Void,
        addFolder: @escaping () -> Void, removeFolder: @escaping (Int) -> Void,
        rescanNow: @escaping () -> Void
    ) {
        self.openConfigFile = openConfigFile
        self.revealConfigFile = revealConfigFile
        self.copyDefaultConfig = copyDefaultConfig
        self.chooseSyncFolder = chooseSyncFolder
        self.addFolder = addFolder
        self.removeFolder = removeFolder
        self.rescanNow = rescanNow
    }
}
