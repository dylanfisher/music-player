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

/// The split of the sidebar, the browser and the queue under `view`.
func firstVerticalSplit(_ view: NSView) -> NSSplitView? {
    if let split = view as? NSSplitView, split.isVertical { return split }
    return view.subviews.lazy.compactMap(firstVerticalSplit).first
}

/// A copy of the fixture library in a fresh temporary folder, for a test that writes to it.
func writableWindowLibrary() throws -> URL {
    let source = try windowLibrary.get()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("main-window-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appendingPathComponent("library.sqlite")
    for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: source.path + suffix) {
        try FileManager.default.copyItem(
            atPath: source.path + suffix, toPath: databaseURL.path + suffix)
    }
    return databaseURL
}

/// The main window as the app builds it, with the browser, toolbar, queue and the status bar's
/// parts, over the fixture library or the one at `databaseURL`. Its config and state are in
/// `home`, a temporary one of its own unless given, and it opens as they say, as a launch does.
/// `fillsWindow` lays the sidebar, browser and queue out over the whole window, as the app does.
@MainActor
struct MainWindowFixture {
    let window: MainWindow
    let browser: LibraryBrowser
    let nowPlaying: NowPlayingBar
    let home: URL
    /// Whether `home` is the fixture's own, which `close` deletes.
    private let ownsHome: Bool
    let settings: ConfigStore<AppSettings>
    let state: StateStore<AppState>
    let saver: LayoutSaver

    init(
        home: URL? = nil, databaseURL: URL? = nil, fillsWindow: Bool = false, glass: Bool = false,
        statusBar: BarLayout<StatusPart> = .defaultStatusBar
    ) async throws {
        ownsHome = home == nil
        let home =
            home
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("main-window-\(UUID().uuidString)", isDirectory: true)
        self.home = home
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paths = AppPaths(home: home)
        let databaseURL = try databaseURL ?? windowLibrary.get()
        settings = ConfigStore(
            AppSettings(), fileURL: paths.configFile, check: try shortcutCheck(), creating: true)
        state = try StateStore(AppState(), fileURL: paths.stateFile)
        saver = LayoutSaver(state)
        var layout = WindowSettings(settings, state: state)
        layout.tableAppearance.glass = glass
        let index = try LibraryIndex(at: databaseURL)
        browser = LibraryBrowser(
            reader: try LibraryReader(databaseURL: databaseURL), index: index,
            layout: layout.trackTable, browserHeight: layout.browserHeight,
            groupByAlbumArtist: false, thumbnails: nil)
        browser.setTableAppearance(layout.tableAppearance)
        browser.statsHeight = layout.statsHeight
        let lookup = { (path: String) in try index.track(path: path) }
        nowPlaying = NowPlayingBar(
            model: NowPlayingModel(lookup: lookup),
            artwork: ArtworkLoader(maxPixelSize: 8, capacity: 1))
        connectRatings(browser, nowPlaying) {}
        let dispatcher = CommandDispatcher(
            bindings: try KeyBindings(
                AppCommands.all(), overrides: [:], rules: AppMenus.rules(appName: "App")))
        let toolbar = MainToolbar(
            identifier: UUID().uuidString, transport: nowPlaying.transport,
            status: nowPlaying.status, customStatuses: nowPlaying.customStatuses.map(\.view),
            search: browser.searchField, dispatcher: dispatcher, items: ToolbarItem.defaultItems)
        window = MainWindow(
            settings: layout, banner: ConfigBanner().view, browser: browser, toolbar: toolbar,
            signalPath: SignalPathPanel(), queue: QueuePanel(model: QueueModel(lookup: lookup)),
            saver: saver)
        if fillsWindow {
            // In a test run the window's stack leaves the split at its fitting height, about
            // one row, where the app's fills the window (`--snapshot` shows it), so the
            // browser's panes and rows have no room. Pinned to the bottom, it lays out as the
            // app's does.
            guard let split = window.window.contentView.flatMap(firstVerticalSplit),
                let item = split.superview, let stack = item.superview
            else { preconditionFailure("the main window has no split in a stack") }
            item.bottomAnchor.constraint(equalTo: stack.bottomAnchor).isActive = true
            window.window.layoutIfNeeded()
            browser.restoreSplit()
        }
        window.showTitles(of: nowPlaying, layout.windowTitle)
        setLayout(statusBar)
        window.window.orderFront(nil)
        await browser.load(layout.browser, resume: layout.resume)
        window.window.layoutIfNeeded()
    }

    /// Lays the status bar out with `parts` in a flexible center column.
    func setParts(_ parts: [StatusPart], style: StatusBarStyle = .minimal) {
        setLayout(.centered(parts), style: style)
    }

    /// Lays the status bar out as `layout` says, as a change of the setting does.
    func setLayout(_ layout: BarLayout<StatusPart>, style: StatusBarStyle = .minimal) {
        nowPlaying.statusBar.apply(style)
        browser.setStatusBar(
            StatusBarLayout(columns: layout, style: style),
            views: Dictionary(
                uniqueKeysWithValues: StatusPart.allCases.compactMap { part in
                    nowPlaying.statusBar.view(for: part).map { (part, $0) }
                }))
        window.window.layoutIfNeeded()
    }

    /// The window's size and every split view's panes, in window coordinates. The window's
    /// origin is left out: it opens on the main screen, which follows what the user is doing
    /// with a second display, so two fixtures can open on different screens.
    var layout: [NSRect] {
        var frames = [NSRect(origin: .zero, size: window.window.frame.size)]
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
        if ownsHome { try? FileManager.default.removeItem(at: home) }
    }
}

extension BarLayout<StatusPart> {
    /// `parts` alone, in a flexible center column.
    static func centered(_ parts: [StatusPart]) -> Self {
        BarLayout(center: BarColumn(parts: parts, width: .flexible, alignment: .center))
    }
}
