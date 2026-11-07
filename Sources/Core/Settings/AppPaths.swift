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
    /// The Discogs catalog the dumps are imported into, unless `discogs.catalogPath` names
    /// another file (ADR 0130).
    var discogsCatalogFile: URL { dataDirectory.appendingPathComponent("discogs.sqlite") }

    /// The Discogs catalog's file: `catalogPath`, the setting's value, or the default.
    func discogsCatalogFile(_ catalogPath: String?) -> URL {
        catalogPath.map { URL(fileURLWithPath: $0, isDirectory: false) } ?? discogsCatalogFile
    }
    /// The art column's thumbnails.
    public var thumbnailDirectory: URL { cacheDirectory.appendingPathComponent("Thumbnails") }
    /// The Spectrum window's spectrograms (phase 45).
    public var spectrogramDirectory: URL { cacheDirectory.appendingPathComponent("Spectrograms") }
}
