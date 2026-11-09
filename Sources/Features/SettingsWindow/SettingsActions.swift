import Settings

/// What the Settings window asks the app to do with the config file, the library and its
/// snapshots.
public struct SettingsActions {
    public var openConfigFile: () -> Void
    public var revealConfigFile: () -> Void
    public var copyDefaultConfig: () -> Void
    /// Asks for a folder and makes it the sync folder.
    public var chooseSyncFolder: () -> Void
    /// Opens the sync folder in Finder where it is now.
    public var openSyncFolder: () -> Void
    /// Asks for a folder and makes it the staging folder.
    public var chooseStagingFolder: () -> Void
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
    /// Shows Library Health in the main window, from the Browsing section's button.
    public var showHealth: () -> Void
    /// The index's place and size and the snapshots, which the Database section shows.
    public var libraryDatabase: () async throws -> LibraryDatabase
    /// Shows the index's file in Finder.
    public var revealIndex: () -> Void
    /// Back Up Now: writes the day's snapshot between scans, and returns once it's written or
    /// failed.
    public var backUpNow: () async -> Void
    /// Restore… on a snapshot: asks first, then relaunches into it.
    public var restoreSnapshot: (LibraryDatabase.Snapshot) -> Void

    public init(
        openConfigFile: @escaping () -> Void, revealConfigFile: @escaping () -> Void,
        copyDefaultConfig: @escaping () -> Void, chooseSyncFolder: @escaping () -> Void,
        openSyncFolder: @escaping () -> Void, chooseStagingFolder: @escaping () -> Void,
        addFolder: @escaping () -> Void, removeFolder: @escaping (Int) -> Void,
        rescanNow: @escaping () -> Void, rescanFolders: @escaping ([Int]) -> Void,
        outputs: @escaping () -> [OutputOption],
        searchOutputs: @escaping () -> Void, chooseOutput: @escaping (OutputChoice) -> Void,
        showHealth: @escaping () -> Void,
        libraryDatabase: @escaping () async throws -> LibraryDatabase,
        revealIndex: @escaping () -> Void, backUpNow: @escaping () async -> Void,
        restoreSnapshot: @escaping (LibraryDatabase.Snapshot) -> Void
    ) {
        self.openConfigFile = openConfigFile
        self.revealConfigFile = revealConfigFile
        self.copyDefaultConfig = copyDefaultConfig
        self.chooseSyncFolder = chooseSyncFolder
        self.openSyncFolder = openSyncFolder
        self.chooseStagingFolder = chooseStagingFolder
        self.addFolder = addFolder
        self.removeFolder = removeFolder
        self.rescanNow = rescanNow
        self.rescanFolders = rescanFolders
        self.outputs = outputs
        self.searchOutputs = searchOutputs
        self.chooseOutput = chooseOutput
        self.showHealth = showHealth
        self.libraryDatabase = libraryDatabase
        self.revealIndex = revealIndex
        self.backUpNow = backUpNow
        self.restoreSnapshot = restoreSnapshot
    }
}
