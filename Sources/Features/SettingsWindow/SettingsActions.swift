import Settings

/// What the Settings window asks the app to do with the config file and the library.
public struct SettingsActions {
    public var openConfigFile: () -> Void
    public var revealConfigFile: () -> Void
    public var copyDefaultConfig: () -> Void
    /// Asks for a folder and makes it the sync folder.
    public var chooseSyncFolder: () -> Void
    /// Opens the sync folder in Finder where it is now.
    public var openSyncFolder: () -> Void
    /// Asks for a folder to watch.
    public var addFolder: () -> Void
    /// Asks to stop watching the folder at this position in the setting.
    public var removeFolder: (Int) -> Void
    public var rescanNow: () -> Void
    /// Rescans the folders at these positions in the setting.
    public var rescanFolders: ([Int]) -> Void
    /// The outputs to pick from, as `outputOptions` lists them.
    public var outputs: () -> [OutputOption]
    /// Starts a search for renderers, as the output picker opens; `reload` shows what it finds.
    public var searchOutputs: () -> Void
    public var chooseOutput: (OutputChoice) -> Void

    public init(
        openConfigFile: @escaping () -> Void, revealConfigFile: @escaping () -> Void,
        copyDefaultConfig: @escaping () -> Void, chooseSyncFolder: @escaping () -> Void,
        openSyncFolder: @escaping () -> Void,
        addFolder: @escaping () -> Void, removeFolder: @escaping (Int) -> Void,
        rescanNow: @escaping () -> Void, rescanFolders: @escaping ([Int]) -> Void,
        outputs: @escaping () -> [OutputOption],
        searchOutputs: @escaping () -> Void, chooseOutput: @escaping (OutputChoice) -> Void
    ) {
        self.openConfigFile = openConfigFile
        self.revealConfigFile = revealConfigFile
        self.copyDefaultConfig = copyDefaultConfig
        self.chooseSyncFolder = chooseSyncFolder
        self.openSyncFolder = openSyncFolder
        self.addFolder = addFolder
        self.removeFolder = removeFolder
        self.rescanNow = rescanNow
        self.rescanFolders = rescanFolders
        self.outputs = outputs
        self.searchOutputs = searchOutputs
        self.chooseOutput = chooseOutput
    }
}
