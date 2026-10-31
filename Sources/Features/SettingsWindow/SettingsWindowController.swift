import AppKit
import Commands
import Settings

/// The Settings window: one window with a toolbar of panes, General and Shortcuts. Made on first
/// use and kept.
@MainActor
public final class SettingsWindowController: NSObject, NSToolbarDelegate {
    public enum Pane: String, CaseIterable {
        case general, shortcuts

        var title: String {
            switch self {
            case .general: "General"
            case .shortcuts: "Shortcuts"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .shortcuts: "keyboard"
            }
        }
    }

    public let window: NSWindow
    private let general: GeneralPane
    private let shortcuts: ShortcutsPane
    private var centered = false

    public init(
        general: GeneralModel, shortcuts: ShortcutsModel, configPath: String,
        actions: SettingsActions
    ) {
        self.general = GeneralPane(model: general, configPath: configPath, actions: actions)
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

    /// Opens General at one setting's row, as the palette asks.
    public func show(setting key: String) {
        show(.general)
        general.focus(key)
    }

    /// Shows the settings and shortcuts as they are now, after any change.
    public func reload(bindings: KeyBindings) {
        general.reload()
        shortcuts.model.update(bindings)
        if shortcuts.isViewLoaded { shortcuts.reload() }
    }

    private func select(_ pane: Pane) {
        let controller: NSViewController = pane == .general ? general : shortcuts
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
