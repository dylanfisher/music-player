import AppKit
import Commands
import Settings

/// The Settings window: one window with a toolbar of panes, General, Playback, Appearance,
/// Watched Folders and Shortcuts. Made on first use and kept.
@MainActor
public final class SettingsWindowController: NSObject, NSToolbarDelegate {
    public enum Pane: String, CaseIterable {
        case general, playback, appearance, folders, shortcuts

        var title: String {
            switch self {
            case .general: "General"
            case .playback: "Playback"
            case .appearance: AppSettings().appearance.title
            case .folders: AppSettings().watchedFolders.title
            case .shortcuts: "Shortcuts"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .playback: "speaker.wave.2"
            case .appearance: "paintbrush"
            case .folders: "folder"
            case .shortcuts: "keyboard"
            }
        }
    }

    public let window: NSWindow
    private let model: GeneralModel
    private let actions: SettingsActions
    private let general: GeneralPane
    private let playback: GeneralPane
    private let appearance: GeneralPane
    private let folders: FoldersPane
    private let shortcuts: ShortcutsPane
    private var centered = false

    public init(
        general: GeneralModel, shortcuts: ShortcutsModel, configPath: String,
        actions: SettingsActions
    ) {
        model = general
        self.actions = actions
        let playbackSections: [GeneralModel.Section] = [.output, .playCounts]
        self.general = GeneralPane(
            model: general, configPath: configPath, actions: actions,
            sections: GeneralModel.Section.allCases.filter {
                !playbackSections.contains($0) && ![.appearance, .networkFolders].contains($0)
            })
        playback = GeneralPane(
            model: general, configPath: nil, actions: actions, sections: playbackSections)
        appearance = GeneralPane(
            model: general, configPath: nil, actions: actions, sections: [.appearance])
        folders = FoldersPane(model: general, actions: actions)
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

    /// Brings the window forward at `pane`, centered the first time.
    public func show(_ pane: Pane = .general) {
        select(pane)
        if !centered {
            window.center()
            centered = true
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens the pane with one setting's row at that row, as the palette asks, or the config
    /// file for a setting the window doesn't show.
    public func show(setting key: String) {
        guard key != folders.key else { return show(.folders) }
        guard model.rows.contains(where: { $0.key == key }) else {
            return actions.openConfigFile()
        }
        switch GeneralModel.Section(key: key) {
        case .output, .playCounts:
            show(.playback)
            playback.focus(key)
        case .appearance:
            show(.appearance)
            appearance.focus(key)
        case .networkFolders:
            show(.folders)
            folders.focus(key)
        default:
            show(.general)
            general.focus(key)
        }
    }

    /// Opens the bar builder on the bar layout setting `key`, from Settings ▸ Appearance.
    public func showBarBuilder(_ key: String) { appearance.showBarBuilder(key) }

    /// The bar builder's window for `key`, once opened.
    public func barBuilderWindow(_ key: String) -> NSWindow? {
        appearance.barBuilders[key]?.window
    }

    /// Shows the settings and shortcuts as they are now, after any change.
    public func reload(bindings: KeyBindings) {
        general.reload()
        playback.reload()
        appearance.reload()
        if folders.isViewLoaded { folders.reload() }
        shortcuts.model.update(bindings)
        if shortcuts.isViewLoaded { shortcuts.reload() }
    }

    private func select(_ pane: Pane) {
        let controller: NSViewController =
            switch pane {
            case .general: general
            case .playback: playback
            case .appearance: appearance
            case .folders: folders
            case .shortcuts: shortcuts
            }
        window.contentViewController = controller
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
