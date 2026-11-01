/// What the Settings window asks the app to do with the config file.
public struct SettingsActions {
    public var openConfigFile: () -> Void
    public var revealConfigFile: () -> Void
    public var copyDefaultConfig: () -> Void
    /// Asks for a folder and makes it the sync folder.
    public var chooseSyncFolder: () -> Void

    public init(
        openConfigFile: @escaping () -> Void, revealConfigFile: @escaping () -> Void,
        copyDefaultConfig: @escaping () -> Void, chooseSyncFolder: @escaping () -> Void
    ) {
        self.openConfigFile = openConfigFile
        self.revealConfigFile = revealConfigFile
        self.copyDefaultConfig = copyDefaultConfig
        self.chooseSyncFolder = chooseSyncFolder
    }
}
