import AppKit
import Foundation
import Testing

@testable import Artwork
@testable import Commands
@testable import Fixtures
@testable import Library
@testable import LibraryBrowser
@testable import MusicPlayer
@testable import NowPlaying
@testable import QueueView
@testable import Settings
@testable import SettingsWindow

/// A fixture library of this target's own for the windows below, scanned once per run.
private let windowLibrary = Result { () throws -> URL in
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/main-window-tests")
    _ = try generateFixtures(count: 40, in: root)
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("main-window-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("library.sqlite")
    _ = try LibraryScanner(databaseURL: databaseURL).scan(
        WatchedFolder(path: root.path, kind: .local))
    return databaseURL
}

/// The main window as the app builds it, with the browser, toolbar, queue and the status bar's
/// parts, over the fixture library, its config and state in a temporary home.
@MainActor
struct MainWindowFixture {
    let window: MainWindow
    let browser: LibraryBrowser
    let nowPlaying: NowPlayingBar
    let home: URL

    init(glass: Bool = false, parts: [StatusPart] = [.totals]) async throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("main-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paths = AppPaths(home: home)
        let databaseURL = try windowLibrary.get()
        let settings = ConfigStore(
            AppSettings(), fileURL: paths.configFile, check: try shortcutCheck(), creating: true)
        let state = try StateStore(AppState(), fileURL: paths.stateFile)
        var layout = WindowSettings(settings, state: state)
        layout.tableAppearance.glass = glass
        let index = try LibraryIndex(at: databaseURL)
        browser = LibraryBrowser(
            reader: try LibraryReader(databaseURL: databaseURL), index: index,
            layout: layout.trackTable, browserHeight: layout.browserHeight,
            groupByAlbumArtist: false, thumbnails: nil)
        browser.setTableAppearance(layout.tableAppearance)
        let lookup = { (path: String) in try index.track(path: path) }
        nowPlaying = NowPlayingBar(
            model: NowPlayingModel(lookup: lookup),
            artwork: ArtworkLoader(maxPixelSize: 8, capacity: 1))
        let dispatcher = CommandDispatcher(
            bindings: try KeyBindings(
                AppCommands.all(), overrides: [:], rules: AppMenus.rules(appName: "App")))
        let toolbar = MainToolbar(
            identifier: UUID().uuidString, transport: nowPlaying.transport,
            status: nowPlaying.status, search: browser.searchField, dispatcher: dispatcher,
            items: ToolbarItem.defaultItems)
        window = MainWindow(
            settings: layout, banner: ConfigBanner().view, browser: browser, toolbar: toolbar,
            signalPath: SignalPathPanel(), queue: QueuePanel(model: QueueModel(lookup: lookup)),
            saver: LayoutSaver(state))
        setParts(parts)
        window.window.orderFront(nil)
        await browser.load(BrowserState(source: nil))
        window.window.layoutIfNeeded()
    }

    /// Lays the status bar out with `parts`, as a change of the setting does.
    func setParts(_ parts: [StatusPart], style: StatusBarStyle = .minimal) {
        nowPlaying.statusBar.apply(style)
        browser.setStatusBar(
            StatusBarLayout(parts: parts, style: style),
            views: Dictionary(
                uniqueKeysWithValues: StatusPart.allCases.compactMap { part in
                    nowPlaying.statusBar.view(for: part).map { (part, $0) }
                }))
        window.window.layoutIfNeeded()
    }

    /// The window's frame and every split view's panes, in window coordinates.
    var layout: [NSRect] {
        var frames = [window.window.frame]
        func walk(_ view: NSView) {
            if let split = view as? NSSplitView {
                frames += split.arrangedSubviews.map { $0.convert($0.bounds, to: nil) }
            }
            view.subviews.forEach(walk)
        }
        window.window.contentView.map(walk)
        return frames
    }

    /// How every list in the window draws: its grid, background, rows and header cells, and
    /// whether its scroll view draws a background.
    var tableLooks: [String] {
        var looks: [String] = []
        func walk(_ view: NSView) {
            if let table = view as? NSTableView {
                let scroll = table.enclosingScrollView
                looks.append(
                    [
                        "\(type(of: table)) grid \(table.gridStyleMask.rawValue)",
                        // As set: the track list holds it resolved for the appearance (ADR 0086).
                        "\(table.gridColor) \(background(table))",
                        "alternating \(table.usesAlternatingRowBackgroundColors)",
                        "translucent \((table as? KeyTableView)?.drawsTranslucentRows == true)",
                        "rows \(table.rowHeight) \(table.intercellSpacing) \(table.style.rawValue)",
                        "headers \(table.tableColumns.map { "\(type(of: $0.headerCell))" })",
                        "scroll \(scroll?.drawsBackground == true) \(scroll?.backgroundColor ?? .clear)",
                        "row views \(rowViewColors(table))",
                    ].joined(separator: ", "))
            }
            view.subviews.forEach(walk)
        }
        window.window.contentView.map(walk)
        return looks
    }

    /// The background each row view on screen has, which AppKit sets as it adds the row and
    /// glass sets as it tints it.
    private func rowViewColors(_ table: NSTableView) -> [String] {
        var colors: [String] = []
        table.enumerateAvailableRowViews { rowView, row in
            colors.append("\(row) \(rowView.backgroundColor)")
        }
        return colors.sorted()
    }

    private func background(_ table: NSTableView) -> NSColor {
        (table as? ResolvedBackgroundTable)?.backgroundAsSet ?? table.backgroundColor
    }

    func close() {
        window.window.close()
        try? FileManager.default.removeItem(at: home)
    }
}
