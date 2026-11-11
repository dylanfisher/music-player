import AppKit
import Commands
import KeyChord
import Settings

/// The menu bar and the track menu, built from `AppMenus`. Each command's item shows the first of its chords that
/// can be a key equivalent, and a hidden item beside it carries the second, so both work from
/// the menu bar. Items run their commands through the dispatcher, which also decides whether
/// they're on.
@MainActor
final class MainMenu: NSObject, NSMenuItemValidation {
    let bar = NSMenu()
    /// The context menu of the track table and the timeline.
    let trackMenu = NSMenu()
    /// For `NSApp.windowsMenu` and `NSApp.helpMenu`, which the app sets.
    private(set) var windowsMenu: NSMenu?
    private(set) var helpMenu: NSMenu?
    /// The submenus the app fills as they open, by title.
    private(set) var liveMenus: [String: NSMenu] = [:]
    private let dispatcher: CommandDispatcher
    /// Each command's shown item and its hidden alternate, and whether its menu shows chords.
    private var items: [(id: CommandID, shown: NSMenuItem, hidden: NSMenuItem, chords: Bool)] =
        []
    /// How many of `items` are the bar's; the track menu's follow.
    private var barItemCount = 0

    init(dispatcher: CommandDispatcher, appName: String, settings: AppSettings) {
        self.dispatcher = dispatcher
        super.init()
        let generated = SettingCommand.all(settings)
        let descriptors = Dictionary(uniqueKeysWithValues: settings.settings.map { ($0.key, $0) })
        for section in AppMenus.sections(appName: appName) {
            let menu = NSMenu(title: section.title)
            add(section.entries, to: menu, chords: true, generated, descriptors)
            bar.addItem(withTitle: section.title, action: nil, keyEquivalent: "").submenu = menu
            switch section.role {
            case .window: windowsMenu = menu
            case .help: helpMenu = menu
            case .app, .plain: break
            }
        }
        // Hidden, so a shortcut given to a setting that no menu lists still runs it.
        if let menu = bar.items.first?.submenu {
            for id in AppMenus.settingCommandsOffMenus(appName: appName, settings: settings) {
                addCommand(id, to: menu, chords: true, hidden: true)
            }
        }
        barItemCount = items.count
        add(AppMenus.trackMenu, to: trackMenu, chords: true, generated, descriptors)
        showChords()
    }

    private func add(
        _ entries: [MenuEntry], to menu: NSMenu, chords: Bool, _ generated: [SettingCommand],
        _ descriptors: [String: SettingDescriptor]
    ) {
        for entry in entries {
            switch entry {
            case .command(let id):
                addCommand(id, to: menu, chords: chords)
            case .standard(let item):
                let shown = NSMenuItem(
                    title: item.title, action: NSSelectorFromString(item.action),
                    keyEquivalent: "")
                item.chord.map { setChord($0, of: shown) }
                menu.addItem(shown)
                if let id = item.runs {
                    // The alternate of the command an Edit item runs sends the item's action.
                    let hidden = hiddenItem(action: shown.action, id: id)
                    menu.addItem(hidden)
                    items.append((id, shown, hidden, false))
                }
            case .submenu(let title, let entries, let showsChords):
                let submenu = NSMenu(title: title)
                add(entries, to: submenu, chords: showsChords, generated, descriptors)
                menu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = submenu
            case .setting(let key):
                let commands = generated.filter { $0.key == key }
                guard let descriptor = descriptors[key], !commands.isEmpty else {
                    preconditionFailure("the menus list \(key), which makes no commands")
                }
                if case .choice = descriptor.kind {
                    let submenu = NSMenu(title: descriptor.title)
                    for command in commands {
                        addCommand(command.command.id, to: submenu, chords: chords)
                    }
                    menu.addItem(withTitle: descriptor.title, action: nil, keyEquivalent: "")
                        .submenu = submenu
                } else {
                    for command in commands {
                        addCommand(command.command.id, to: menu, chords: chords)
                    }
                }
            case .live(let title):
                let submenu = NSMenu(title: title)
                liveMenus[title] = submenu
                menu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = submenu
            case .separator:
                menu.addItem(.separator())
            }
        }
    }

    /// Adds `id`'s item and its hidden alternate; `hidden` hides the item too, keeping its chord.
    private func addCommand(_ id: CommandID, to menu: NSMenu, chords: Bool, hidden: Bool = false) {
        guard let command = dispatcher.bindings.defaults.command(id) else {
            preconditionFailure("the menus list \(id), which isn't a registered command")
        }
        let shown =
            hidden
            ? hiddenItem(action: #selector(runCommand(_:)), id: id)
            : NSMenuItem(
                title: command.title, action: #selector(runCommand(_:)), keyEquivalent: "")
        shown.target = self
        shown.representedObject = id
        let alternate = hiddenItem(action: #selector(runCommand(_:)), id: id)
        alternate.target = self
        menu.addItem(shown)
        menu.addItem(alternate)
        items.append((id, shown, alternate, chords))
    }

    private func hiddenItem(action: Selector?, id: CommandID) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.representedObject = id
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    /// Sets every command item's key equivalent from the dispatcher's bindings, after they
    /// change. An Edit item's own chord is fixed, so only its hidden alternate changes.
    func showChords() {
        let bindings = dispatcher.bindings
        for (id, shown, hidden, showsChords) in items {
            let usable = (bindings.registry.command(id)?.chords ?? []).filter(\.canBeKeyEquivalent)
            if shown.action == #selector(runCommand(_:)) {
                setChord(showsChords ? usable.first : nil, of: shown)
                setChord(usable.dropFirst().first, of: hidden)
            } else {
                setChord(usable.first { $0 != bindings.rules.fixed[id] }, of: hidden)
            }
        }
    }

    private func setChord(_ chord: KeyChord?, of item: NSMenuItem) {
        item.keyEquivalent = chord?.keyEquivalent ?? ""
        item.keyEquivalentModifierMask = chord?.keyEquivalentModifierMask ?? []
    }

    @objc func runCommand(_ item: NSMenuItem) {
        guard let id = item.representedObject as? CommandID else { return }
        if !dispatcher.run(id) { NSSound.beep() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let id = item.representedObject as? CommandID else { return true }
        item.state =
            dispatcher.isMixed(id) ? .mixed : dispatcher.isOn(id) == true ? .on : .off
        if !item.isHidden, let title = dispatcher.title(id) { item.title = title }
        return dispatcher.isEnabled(id)
    }

    /// The commands the bar's visible items run, for the test that every command has one.
    var listedCommands: [CommandID] {
        items.prefix(barItemCount).filter { !$0.shown.isHidden }.map(\.id)
    }
}
