import AppKit
import Foundation
import Testing

@testable import Fixtures
@testable import Library
@testable import LibraryBrowser
@testable import MusicPlayer
@testable import Settings

/// A fixture library of this target's own, apart from the other targets' copies, since the
/// targets run in one process.
private let music = Result { () throws -> URL in
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/music-player-tests")
    _ = try generateFixtures(count: 12, in: root)
    return root
}

/// The events a watcher sent, read on the main actor while it sends them on its own threads.
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [WatcherEvent] = []

    func append(_ event: WatcherEvent) { lock.withLock { seen.append(event) } }
    var launchEnded: Bool {
        lock.withLock { seen.contains { if case .launchScansEnded = $0 { true } else { false } } }
    }
    var all: [WatcherEvent] { lock.withLock { seen } }
}

/// A config file with a problem, with `@folder` for the watched folder's JSON, and whether the
/// rest of it still applies, the watched folders with it.
private let brokenConfigs: [(text: String, watching: Bool)] = [
    // The key phase 34 found on the owner's Mac, removed in 4d0a177.
    (#"{"library.watchedFolders": [@folder], "appearance.nowPlaying": "detailed"}"#, true),
    (#"{"library.watchedFolders": [@folder],, "appearance.glass": true}"#, false),
    (#"{"library.watchedFolders": [@folder], "appearance.glass": 1}"#, false),
    (#"{"library.watchedFolders": [{"path": "/Music"}]}"#, false),
]

/// A home folder over an indexed copy of the fixture library, and how many tracks it holds.
private struct IndexedHome {
    let home: URL
    let paths: AppPaths
    let databaseURL: URL
    let folder: WatchedFolder
    let index: LibraryIndex
    let tracks: Int

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = AppPaths(home: home)
        databaseURL = libraryFileURL(in: paths.dataDirectory)
        folder = WatchedFolder(path: try music.get().path, kind: .local)
        _ = try LibraryScanner(databaseURL: databaseURL).scan(folder)
        index = try LibraryIndex(at: databaseURL)
        tracks = try index.trackCount()
    }

    /// The config as the app reads it at launch.
    @MainActor func settings() throws -> ConfigStore<AppSettings> {
        ConfigStore(
            AppSettings(), fileURL: paths.configFile, check: try shortcutCheck(), creating: true)
    }

    /// Starts the watcher as the app does, and waits for its launch scans and the removal
    /// beside them.
    @MainActor func launch(_ settings: ConfigStore<AppSettings>, _ events: Events) async throws
        -> LibraryWatcher?
    {
        let watcher = startedWatcher(settings, databaseURL: databaseURL, events: events.append)
        guard watcher != nil else { return nil }
        let deadline = Date().addingTimeInterval(30)
        while !events.launchEnded, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(events.launchEnded, "\(events.all)")
        try await Task.sleep(nanoseconds: 500_000_000)
        return watcher
    }

    /// Whether the track list shows rows.
    @MainActor func rowsShow() async throws -> Bool {
        let browser = LibraryBrowser(
            reader: try LibraryReader(databaseURL: databaseURL), index: index,
            layout: AppState().trackTable.defaultValue, browserHeight: 100,
            groupByAlbumArtist: false, thumbnails: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.contentView = browser.content.view
        await browser.load(BrowserState(source: nil))
        let deadline = Date().addingTimeInterval(10)
        while browser.rowID(at: 0) == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return browser.rowID(at: 0) != nil
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

/// The launch path from reading the config to the watcher, over an indexed library: no file
/// leaves the index, and the track list shows them (ADR 0082). Before, a config with a problem
/// left `library.watchedFolders` at its default, no folders, and the watcher removed every file
/// as outside them.
@MainActor @Test(arguments: brokenConfigs.indices)
func aConfigWithAProblemNeverEmptiesTheLibrary(_ which: Int) async throws {
    let library = try IndexedHome()
    defer { library.remove() }
    #expect(library.tracks > 0)
    let config = brokenConfigs[which]
    try Data(
        config.text.replacingOccurrences(of: "@folder", with: jsonText(library.folder)).utf8
    ).write(to: library.paths.configFile)
    let settings = try library.settings()
    #expect(!settings.problems.isEmpty)
    let events = Events()
    let watcher = try await library.launch(settings, events)
    defer { watcher?.stop() }
    #expect((watcher != nil) == config.watching)
    #expect(try library.index.trackCount() == library.tracks, "\(events.all)")
    #expect(try await library.rowsShow())
}

/// A config deleted or lost: the app writes one with no watched folders, and neither that launch
/// nor the next, which reads it, removes a file.
@MainActor @Test func aLostConfigKeepsEveryRowOverTwoLaunches() async throws {
    let library = try IndexedHome()
    defer { library.remove() }
    for _ in 0..<2 {
        let settings = try library.settings()
        #expect(settings.fileValue(\.watchedFolders) == [])
        #expect(unwatchedNotice(settings) == nil)
        let events = Events()
        let watcher = try await library.launch(settings, events)
        #expect(watcher != nil)
        watcher?.stop()
        #expect(try library.index.trackCount() == library.tracks, "\(events.all)")
    }
    #expect(try await library.rowsShow())
}

/// Adding a folder in the app while the file is blocked is refused: memory holds no folders then,
/// so the change would have watched only the new one, removed the rest, and been written over
/// the fix.
@MainActor @Test func aFolderChangeWhileTheFileIsBlockedIsRefused() async throws {
    let library = try IndexedHome()
    defer { library.remove() }
    let text = #"{"library.watchedFolders": [@folder], "appearance.glass": 1}"#
        .replacingOccurrences(of: "@folder", with: jsonText(library.folder))
    try Data(text.utf8).write(to: library.paths.configFile)
    let settings = try library.settings()
    let added = WatchedFolder(path: library.home.appendingPathComponent("X").path, kind: .local)
    #expect(throws: ConfigError.self) { try settings.set(\.watchedFolders, to: [added]) }
    #expect(try await library.launch(settings, Events()) == nil)
    #expect(try library.index.trackCount() == library.tracks)
    #expect(try String(contentsOf: library.paths.configFile, encoding: .utf8) == text)
}

/// Stop Watching on the last folder still takes its tracks out, by its own call, since the
/// watcher never empties the index for no folders.
@MainActor @Test func stoppingTheLastFolderRemovesItsTracks() async throws {
    let library = try IndexedHome()
    defer { library.remove() }
    let settings = try library.settings()
    try settings.set(\.watchedFolders, to: [library.folder])
    var watcher = try await library.launch(settings, Events())
    defer { watcher?.stop() }
    settings.changed = { keys in
        guard keys.contains(settings.schema.watchedFolders.key) else { return }
        watcher?.stop()
        watcher = startedWatcher(settings, databaseURL: library.databaseURL, events: { _ in })
    }
    try stopWatching(library.folder, settings) { watcher }
    #expect(settings[\.watchedFolders].isEmpty)
    let deadline = Date().addingTimeInterval(20)
    while try library.index.trackCount() > 0, Date() < deadline {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(try library.index.trackCount() == 0)
}

@MainActor @Test func aConfigThatDoesntNameTheFoldersSaysSoInTheBanner() throws {
    let library = try IndexedHome()
    defer { library.remove() }
    try Data(#"{"appearance.glass": true}"#.utf8).write(to: library.paths.configFile)
    let settings = try library.settings()
    #expect(settings.problems.isEmpty)
    #expect(unwatchedNotice(settings)?.contains("library.watchedFolders") == true)
}
