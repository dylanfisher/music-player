import Foundation
import Log

/// Where the app keeps its files: the config file, and the folder of the library database,
/// the state file and the device record.
public struct AppPaths: Sendable {
    public var configFile: URL
    public var dataDirectory: URL
    /// What the app can make again, which backups skip (ADR 0079).
    var cacheDirectory: URL

    init(configFile: URL, dataDirectory: URL, cacheDirectory: URL) {
        self.configFile = configFile
        self.dataDirectory = dataDirectory
        self.cacheDirectory = cacheDirectory
    }

    /// Everything in one folder, for tests, Bench and runs that must not touch the real files.
    public init(home: URL) {
        self.init(
            configFile: home.appendingPathComponent(configFileName), dataDirectory: home,
            cacheDirectory: home)
    }

    /// `~/.config/music-player/config.json`, `~/Library/Application Support/MusicPlayer` and
    /// `~/Library/Caches/MusicPlayer`.
    public static func standard() throws -> AppPaths {
        func directory(_ kind: FileManager.SearchPathDirectory) throws -> URL {
            try FileManager.default.url(
                for: kind, in: .userDomainMask, appropriateFor: nil, create: false
            ).appendingPathComponent(appDirectoryName)
        }
        return AppPaths(
            configFile: defaultConfigFileURL(),
            dataDirectory: try directory(.applicationSupportDirectory),
            cacheDirectory: try directory(.cachesDirectory))
    }

    public var stateFile: URL { dataDirectory.appendingPathComponent("state.json") }
    /// The art column's thumbnails.
    public var thumbnailDirectory: URL { cacheDirectory.appendingPathComponent("Thumbnails") }
}
