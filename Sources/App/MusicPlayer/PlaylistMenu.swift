import AppKit
import Library

/// The track menu's Add to Playlist and Show in Playlist submenus: the playlists `playlists`
/// gives, listed again each time one opens.
@MainActor
final class PlaylistMenu: NSObject, NSMenuDelegate {
    var playlists: () -> [Playlist] = { [] }
    var choose: (Int64) -> Void = { _ in }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let playlists = playlists()
        // An item with no action is disabled, so the submenu says it has nothing to offer.
        guard !playlists.isEmpty else {
            menu.addItem(withTitle: "No Playlists", action: nil, keyEquivalent: "")
            return
        }
        for playlist in playlists {
            let item = NSMenuItem(
                title: playlist.name, action: #selector(chose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = playlist.id
            menu.addItem(item)
        }
    }

    @objc private func chose(_ item: NSMenuItem) {
        guard let id = item.representedObject as? Int64 else { return }
        choose(id)
    }
}
