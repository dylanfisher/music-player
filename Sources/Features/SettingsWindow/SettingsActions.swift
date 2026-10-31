/// What the Settings window asks the app to do with the config file.
public struct SettingsActions {
    public var openConfigFile: () -> Void
    public var revealConfigFile: () -> Void
    public var copyDefaultConfig: () -> Void

    public init(
        openConfigFile: @escaping () -> Void, revealConfigFile: @escaping () -> Void,
        copyDefaultConfig: @escaping () -> Void
    ) {
        self.openConfigFile = openConfigFile
        self.revealConfigFile = revealConfigFile
        self.copyDefaultConfig = copyDefaultConfig
    }
}
