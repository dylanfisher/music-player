import Foundation
import Settings
import Testing

@testable import MusicPlayer

/// The browser's columns as a launch reads them from `config`, the config file's text (nil for
/// none), and a state file holding `saved`.
@MainActor
private func launchColumns(config: String?, saved: [BrowserColumn]) throws -> [BrowserColumn] {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("window-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let paths = AppPaths(home: home)
    if let config { try Data(config.utf8).write(to: paths.configFile) }
    try StateStore(AppState(), fileURL: paths.stateFile).set(\.browserColumns, to: saved)
    let settings = ConfigStore(
        AppSettings(), fileURL: paths.configFile, check: try shortcutCheck(), creating: false)
    let state = try StateStore(AppState(), fileURL: paths.stateFile)
    return WindowSettings(settings, state: state).browser.columns
}

@MainActor @Test func theConfigsGroupingsGiveTheColumnsAndDropSelectionsMadeInOthers() throws {
    let saved = [
        BrowserColumn(grouping: .genres, selection: "Jazz"),
        BrowserColumn(grouping: .years, selection: "1959"),
        BrowserColumn(grouping: .albums, selection: "Kind of Blue"),
    ]
    #expect(
        try launchColumns(
            config: #"{"browser.columnGroupings": ["genres", "artists", "albums"]}"#, saved: saved)
            == [
                BrowserColumn(grouping: .genres, selection: "Jazz"),
                BrowserColumn(grouping: .artists, selection: nil),
                BrowserColumn(grouping: .albums, selection: "Kind of Blue"),
            ])
    // A config that doesn't name them, or that a problem blocks, leaves the state file's.
    #expect(try launchColumns(config: #"{"appearance.glass": true}"#, saved: saved) == saved)
    #expect(try launchColumns(config: nil, saved: saved) == saved)
    #expect(
        try launchColumns(
            config: #"{"browser.columnGroupings": ["genres", "artists"]}"#, saved: saved) == saved)
}

@MainActor @Test func theSavedSearchLoadsOnlyWhileTheToolbarHasTheSearchField() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("window-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = AppPaths(home: home)
    let settings = ConfigStore(
        AppSettings(), fileURL: paths.configFile, check: try shortcutCheck(), creating: true)
    let state = try StateStore(AppState(), fileURL: paths.stateFile)
    try state.set(\.search, to: "Coltrane")
    #expect(WindowSettings(settings, state: state).browser.search == "Coltrane")
    // Hidden, by Hide Toolbar or Distraction-Free Mode, which saves the same setting.
    try state.set(\.toolbarVisible, to: false)
    #expect(WindowSettings(settings, state: state).browser.search == "")
    try state.set(\.toolbarVisible, to: true)
    try state.set(\.toolbarItems, to: ToolbarItem.defaultItems.filter { $0 != .search })
    #expect(WindowSettings(settings, state: state).browser.search == "")
}
