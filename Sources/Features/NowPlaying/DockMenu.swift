import AppKit
import Commands

/// The Dock icon's menu: the current track, then the transport commands, with the registry's
/// titles. Built again each time the Dock asks, so it's never out of date.
@MainActor
public final class DockMenu: NSObject {
    /// One row of the menu.
    enum Entry: Equatable {
        /// Shown, not chosen: the track's title, or its artist and album.
        case label(String)
        case separator
        case command(CommandID, title: String, enabled: Bool)
    }

    static let commands: [CommandID] = [.playPause, .nextTrack, .previousTrack]

    private let model: NowPlayingModel
    private let dispatcher: CommandDispatcher

    public init(model: NowPlayingModel, dispatcher: CommandDispatcher) {
        self.model = model
        self.dispatcher = dispatcher
    }

    /// The current track shows while it plays or is paused, as in Now Playing.
    func entries() -> [Entry] {
        var entries: [Entry] = []
        if model.state.status != .stopped, model.currentURL != nil {
            entries.append(.label(model.title))
            if !model.subtitle.isEmpty { entries.append(.label(model.subtitle)) }
            entries.append(.separator)
        }
        for id in Self.commands {
            guard let command = dispatcher.bindings.defaults.command(id) else {
                preconditionFailure("the Dock menu lists \(id), which isn't a registered command")
            }
            entries.append(.command(id, title: command.title, enabled: dispatcher.isEnabled(id)))
        }
        return entries
    }

    public func menu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries() {
            switch entry {
            case .label(let text):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case .separator: menu.addItem(.separator())
            case .command(let id, let title, let enabled):
                let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
                item.isEnabled = enabled
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func run(_ item: NSMenuItem) {
        guard let id = item.representedObject as? CommandID else { return }
        if !dispatcher.run(id) { NSSound.beep() }
    }
}
