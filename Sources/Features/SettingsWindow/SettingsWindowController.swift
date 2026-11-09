import AppKit
import Commands
import Settings
import WindowPlacement

/// The Settings window: one window with a toolbar of panes, General, Playback, Appearance,
/// Toolbar, Watched Folders, Tagging and Shortcuts. Made on first use and kept.
@MainActor
public final class SettingsWindowController: NSObject, NSToolbarDelegate {
    public enum Pane: String, CaseIterable {
        case general, playback, appearance, toolbar, folders, tagging, shortcuts

        var title: String {
            switch self {
            case .general: "General"
            case .playback: "Playback"
            case .appearance: AppSettings().appearance.title
            case .toolbar: "Toolbar"
            case .folders: AppSettings().watchedFolders.title
            case .tagging: "Tagging"
            case .shortcuts: "Shortcuts"
            }
        }

        /// The sections of settings the pane shows; General shows those no other pane does.
        var sections: [GeneralModel.Section] {
            switch self {
            case .general, .tagging, .shortcuts: []
            case .playback: [.output, .playCounts]
            case .appearance: [.theme, .trackTable]
            case .toolbar: [.titles, .toolbarStatus, .statusBar]
            case .folders: [.folderChanges, .libraryFolder, .networkFolders]
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .playback: "speaker.wave.2"
            case .appearance: "paintbrush"
            case .toolbar: "menubar.rectangle"
            case .folders: "folder"
            case .tagging: "tag"
            case .shortcuts: "keyboard"
            }
        }
    }

    /// The name the window keeps its frame under; its title is the pane's.
    static let frameName = "Settings Window"

    public let window: NSWindow
    private let model: GeneralModel
    private let actions: SettingsActions
    private let general: GeneralPane
    private let playback: GeneralPane
    private let appearance: GeneralPane
    private let toolbarPane: GeneralPane
    private let folders: LibraryPane
    /// Made as it's first shown, since its model reads the mapping then.
    private(set) var tagging: TaggingPane?
    private let shortcuts: ShortcutsPane
    /// Each pane in its scroll view, made as it's first shown.
    private var scrollers: [Pane: PaneScroller] = [:]

    /// Reads and writes a setting as JSON holds it, for the Tagging pane's model.
    private let settingValue: (String) -> Any?
    private let setSetting: (String, Any) throws -> Void

    /// `value` reads a setting as JSON holds it and `set` writes one, as `general`'s do.
    public init(
        general: GeneralModel, shortcuts: ShortcutsModel, configPath: String,
        actions: SettingsActions, value: @escaping (String) -> Any?,
        set: @escaping (String, Any) throws -> Void
    ) {
        model = general
        self.actions = actions
        settingValue = value
        setSetting = set
        let others = Pane.allCases.flatMap(\.sections)
        self.general = GeneralPane(
            model: general, configPath: configPath, actions: actions,
            sections: GeneralModel.Section.allCases.filter { !others.contains($0) })
        playback = GeneralPane(
            model: general, configPath: nil, actions: actions, sections: Pane.playback.sections)
        appearance = GeneralPane(
            model: general, configPath: nil, actions: actions, sections: Pane.appearance.sections)
        toolbarPane = GeneralPane(
            model: general, configPath: nil, actions: actions, sections: Pane.toolbar.sections)
        folders = LibraryPane(model: general, actions: actions)
        self.shortcuts = ShortcutsPane(model: shortcuts)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: GeneralPane.width, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()
        window.isReleasedWhenClosed = false
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        select(.general)
    }

    /// Brings the window forward at `pane`, where it was left the first time (ADR 0158).
    public func show(_ pane: Pane = .general) {
        select(pane)
        window.keepsFrame(as: Self.frameName)
        // Placed on another screen, a short one, the pane fits that one.
        scrollers[pane]?.fit()
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens the pane with one setting's row at that row, as the palette asks, or the config
    /// file for a setting the window doesn't show.
    public func show(setting key: String) {
        guard key != folders.key else { return show(.folders) }
        guard key != TaggingModel.setting.key else { return show(.tagging) }
        guard model.rows.contains(where: { $0.key == key }) else {
            return actions.openConfigFile()
        }
        let section = GeneralModel.Section(key: key)
        let pane = Pane.allCases.first { $0.sections.contains(section) } ?? .general
        show(pane)
        if pane == .folders {
            folders.focus(key)
        } else {
            (controller(pane) as? GeneralPane)?.focus(key)
        }
    }

    /// Opens the bar builder on the bar layout setting `key`, from Settings ▸ Toolbar.
    public func showBarBuilder(_ key: String) { toolbarPane.showBarBuilder(key) }

    /// The bar builder's window for `key`, once opened.
    public func barBuilderWindow(_ key: String) -> NSWindow? {
        toolbarPane.barBuilders[key]?.window
    }

    /// Shows the settings and shortcuts as they are now, after any change.
    public func reload(bindings: KeyBindings) {
        general.reload()
        playback.reload()
        appearance.reload()
        toolbarPane.reload()
        if folders.isViewLoaded { folders.reload() }
        if let tagging, tagging.isViewLoaded { tagging.reload() }
        shortcuts.model.update(bindings)
        if shortcuts.isViewLoaded { shortcuts.reload() }
    }

    private func controller(_ pane: Pane) -> NSViewController {
        switch pane {
        case .general: general
        case .playback: playback
        case .appearance: appearance
        case .toolbar: toolbarPane
        case .folders: folders
        case .tagging: taggingPane()
        case .shortcuts: shortcuts
        }
    }

    private func taggingPane() -> TaggingPane {
        if let tagging { return tagging }
        let pane = TaggingPane(
            model: TaggingModel(
                value: settingValue, set: setSetting, isBlocked: model.isBlocked))
        tagging = pane
        return pane
    }

    private func select(_ pane: Pane) {
        let scroller =
            scrollers[pane]
            ?? PaneScroller(controller(pane))
        scrollers[pane] = scroller
        window.contentViewController = scroller
        scroller.fit()
        window.title = pane.title
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)
    }

    @objc private func selected(_ item: NSToolbarItem) {
        Pane(rawValue: item.itemIdentifier.rawValue).map(select)
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    public func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier]
    {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    public func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = Pane(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selected(_:))
        return item
    }
}
