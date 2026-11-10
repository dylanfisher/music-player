import Foundation
import Settings
import Testing

@testable import MusicPlayer

private func store() throws -> StateStore<AppState> {
    try StateStore(
        AppState(),
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("saver-\(UUID().uuidString)/settings.json"))
}

@MainActor @Test func theLastValueOfEachSettingIsTheOneSaved() throws {
    let settings = try store()
    let saver = LayoutSaver(settings)
    saver.set(\.sidebarWidth, 200)
    saver.set(\.sidebarWidth, 300)
    saver.set(\.queueVisible, true)
    saver.flush()
    let reloaded = try StateStore(AppState(), fileURL: settings.fileURL)
    #expect(reloaded[\.sidebarWidth] == 300)
    #expect(reloaded[\.queueVisible])
}

@MainActor @Test func theSignalPathIsHiddenUntilShownAndThenStaysShown() throws {
    let settings = try store()
    #expect(!settings[\.signalPathVisible])
    let saver = LayoutSaver(settings)
    saver.set(\.signalPathVisible, true)
    saver.flush()
    #expect(try StateStore(AppState(), fileURL: settings.fileURL)[\.signalPathVisible])
}

@MainActor @Test func aFlushWritesEachChangeOnce() throws {
    let settings = try store()
    let saver = LayoutSaver(settings)
    saver.set(\.sidebarWidth, 200)
    saver.flush()
    try settings.set(\.sidebarWidth, to: 250)
    saver.flush()
    #expect(settings[\.sidebarWidth] == 250)
}

@MainActor @Test func oneBadValueDoesntStopTheOthers() throws {
    let settings = try store()
    let saver = LayoutSaver(settings)
    saver.set(\.sidebarWidth, 5000)
    saver.set(\.queueWidth, 300)
    saver.flush()
    #expect(settings[\.sidebarWidth] == AppState().sidebarWidth.defaultValue)
    #expect(settings[\.queueWidth] == 300)
}

@MainActor @Test func aFailedSaveIsReportedUntilASaveWorks() throws {
    let settings = try store()
    let saver = LayoutSaver(settings)
    var reported = 0
    saver.failureChanged = { reported += 1 }
    saver.set(\.sidebarWidth, 5000)
    saver.flush()
    #expect(saver.failure?.hasPrefix(AppState().sidebarWidth.key) == true)
    #expect(reported == 1)
    saver.set(\.sidebarWidth, 300)
    saver.flush()
    #expect(saver.failure == nil)
    #expect(reported == 2)
}

@MainActor @Test func aFailedSaveIsKeptAndSavedWithTheNext() throws {
    let settings = try store()
    let folder = settings.fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let saver = LayoutSaver(settings)
    // A folder that can't be written fails the save as a full disk does.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    saver.set(\.sidebarWidth, 300)
    saver.flush()
    #expect(saver.failure?.hasPrefix(AppState().sidebarWidth.key) == true)
    #expect(settings[\.sidebarWidth] == AppState().sidebarWidth.defaultValue)

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    saver.set(\.queueWidth, 320)
    saver.flush()
    #expect(saver.failure == nil)
    let reloaded = try StateStore(AppState(), fileURL: settings.fileURL)
    #expect(reloaded[\.sidebarWidth] == 300)
    #expect(reloaded[\.queueWidth] == 320)
}

/// Closing the banner's reset line rewrites the file at once, so it reads back with nothing
/// discarded; a write that fails is reported as any layout save is, and kept for the next.
@MainActor @Test func forgettingTheDiscardRewritesTheFileOrReportsWhyNot() throws {
    let settings = try store()
    let folder = settings.fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(#"{"window.sidebarWidth": 250, "window.old": 1}"#.utf8).write(to: settings.fileURL)
    let state = try StateStore(AppState(), fileURL: settings.fileURL)
    #expect(!state.discarded.isEmpty)
    let saver = LayoutSaver(state)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    saver.forgetDiscarded()
    #expect(saver.failure?.hasPrefix("settings.json: ") == true)
    #expect(!state.discarded.isEmpty)

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    saver.forgetDiscarded()
    #expect(saver.failure == nil)
    #expect(state.discarded.isEmpty)
    let reread = try StateStore(AppState(), fileURL: settings.fileURL)
    #expect(reread.discardReason == nil)
    #expect(reread[\.sidebarWidth] == 250)
}
