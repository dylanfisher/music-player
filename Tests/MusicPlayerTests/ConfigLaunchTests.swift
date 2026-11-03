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

/// The launch path from reading the config to the watcher, over an indexed library: no file
/// leaves the index, and the track list shows them (ADR 0082). Before, a config with a problem
/// left `library.watchedFolders` at its default, no folders, and the watcher removed every file
/// as outside them.
@MainActor @Test(arguments: brokenConfigs.indices)
func aConfigWithAProblemNeverEmptiesTheLibrary(_ which: Int) async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("config-launch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = AppPaths(home: home)
    let databaseURL = libraryFileURL(in: paths.dataDirectory)
    let folder = WatchedFolder(path: try music.get().path, kind: .local)
    _ = try LibraryScanner(databaseURL: databaseURL).scan(folder)
    let index = try LibraryIndex(at: databaseURL)
    let indexed = try index.trackCount()
    #expect(indexed > 0)
    let config = brokenConfigs[which]
    try Data(config.text.replacingOccurrences(of: "@folder", with: jsonText(folder)).utf8).write(
        to: paths.configFile)

    let settings = ConfigStore(
        AppSettings(), fileURL: paths.configFile, check: try shortcutCheck(), creating: true)
    #expect(!settings.problems.isEmpty)
    let events = Events()
    let watcher = startedWatcher(settings, databaseURL: databaseURL, events: events.append)
    defer { watcher?.stop() }
    #expect((watcher != nil) == config.watching)
    if watcher != nil {
        let deadline = Date().addingTimeInterval(30)
        while !events.launchEnded, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(events.launchEnded, "\(events.all)")
        // The removal outside the folders runs beside the scan; give it time to show.
        try await Task.sleep(nanoseconds: 500_000_000)
    }
    #expect(try index.trackCount() == indexed, "\(events.all)")

    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL), index: index,
        layout: AppState().trackTable.defaultValue, browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
        backing: .buffered, defer: true)
    window.contentView = browser.content.view
    await browser.load(BrowserState(source: nil))
    let deadline = Date().addingTimeInterval(10)
    while browser.rowID(at: 0) == nil, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(browser.rowID(at: 0) != nil)
}
