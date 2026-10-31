import Foundation
import Settings
import Testing

@testable import MusicPlayer

private func store() throws -> SettingsStore<AppSettings> {
    try SettingsStore(
        AppSettings(),
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
    let reloaded = try SettingsStore(AppSettings(), fileURL: settings.fileURL)
    #expect(reloaded[\.sidebarWidth] == 300)
    #expect(reloaded[\.queueVisible])
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
    #expect(settings[\.sidebarWidth] == AppSettings().sidebarWidth.defaultValue)
    #expect(settings[\.queueWidth] == 300)
}
