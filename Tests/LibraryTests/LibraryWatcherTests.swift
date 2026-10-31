import Foundation
import Testing

@testable import Library
@testable import Settings

/// Polls `condition` every 100 ms for up to `seconds`.
private func eventually(within seconds: Double, _ condition: () throws -> Bool) async throws
    -> Bool
{
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if try condition() { return true }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    return try condition()
}

@Test func scansAtStartThenFollowsFSEvents() async throws {
    let library = try TestLibrary()
    let settings = try SettingsStore(
        AppSettings(),
        fileURL: library.databaseURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json"))
    try settings.set(\.watchedFolders, to: [library.folder])
    let watcher = LibraryWatcher(settings: settings, databaseURL: library.databaseURL)
    watcher.start()
    defer { watcher.stop() }

    let index = try library.index()
    #expect(try await eventually(within: 20) { try index.trackCount() == library.readableCount })

    let file = library.manifest.files.first { $0.malformation == nil }!
    let source = library.path(file)
    let copy = (source as NSString).deletingLastPathComponent + "/copied in.flac"
    try FileManager.default.copyItem(atPath: source, toPath: copy)
    #expect(
        try await eventually(within: 20) { try index.trackCount() == library.readableCount + 1 })
}
