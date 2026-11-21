import AppKit
import Commands
import DisplayText
import Recommender

/// Fills Show Discography's menu item from a choice: with one artist it opens that artist's
/// discography, with several it's a submenu of them, and with none it's disabled, the reason
/// its tooltip. Menu items hold their target weakly, so whoever fills them keeps this.
@MainActor
final class DiscographyItems: NSObject {
    /// Hears an artist chosen.
    var open: (RecommendationPage.Named) -> Void = { _ in }

    func fill(_ item: NSMenuItem, _ choice: DiscographyChoice) {
        item.submenu = nil
        item.target = nil
        item.action = nil
        item.representedObject = nil
        item.toolTip = nil
        switch choice {
        case .unavailable(let why):
            item.toolTip = why
            item.isEnabled = false
        case .artists(let artists) where artists.count == 1:
            item.isEnabled = true
            choose(item, artists[0])
            item.toolTip = artistName(artists[0])
        case .artists(let artists):
            item.isEnabled = true
            let submenu = NSMenu(title: item.title)
            for artist in artists {
                let choice = NSMenuItem(title: artistName(artist), action: nil, keyEquivalent: "")
                choose(choice, artist)
                submenu.addItem(choice)
            }
            item.submenu = submenu
        }
    }

    private func choose(_ item: NSMenuItem, _ artist: RecommendationPage.Named) {
        item.target = self
        item.action = #selector(chosen)
        item.representedObject = artist
    }

    @objc private func chosen(_ sender: NSMenuItem) {
        guard let artist = sender.representedObject as? RecommendationPage.Named else { return }
        open(artist)
    }
}

/// An artist's name for a menu or the pop-up, or its id when the catalog has no name.
func artistName(_ artist: RecommendationPage.Named) -> String {
    artist.name.map(terminalSafe) ?? "Discogs artist \(artist.id)"
}

/// The track menu's delegate, which fills its Show Discography item each time the menu opens,
/// since that item is a plain item for one artist and a submenu for several (ADR 0217).
@MainActor
final class TrackMenuDiscography: NSObject, NSMenuDelegate {
    var fill: (NSMenuItem) -> Void = { _ in }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let item = menu.item(withTitle: AppMenus.showDiscographyMenuTitle) else {
            preconditionFailure("the track menu has no \(AppMenus.showDiscographyMenuTitle)")
        }
        fill(item)
    }
}
