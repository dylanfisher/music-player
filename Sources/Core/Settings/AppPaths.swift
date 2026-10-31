import Foundation
import Log

/// Where the app keeps its files: the config file, and the folder of the library database,
/// the state file and the device record.
public struct AppPaths: Sendable {
    public var configFile: URL
    public var dataDirectory: URL

    public init(configFile: URL, dataDirectory: URL) {
        self.configFile = configFile
        self.dataDirectory = dataDirectory
    }

    /// Everything in one folder, for tests, Bench and runs that must not touch the real files.
    public init(home: URL) {
        self.init(configFile: home.appendingPathComponent("config.json"), dataDirectory: home)
    }

    /// `~/.config/music-player/config.json` and `~/Library/Application Support/MusicPlayer`.
    public static func standard() throws -> AppPaths {
        AppPaths(
            configFile: defaultConfigFileURL(),
            dataDirectory: try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                create: false
            ).appendingPathComponent(appDirectoryName))
    }

    public var stateFile: URL { dataDirectory.appendingPathComponent("state.json") }
}
