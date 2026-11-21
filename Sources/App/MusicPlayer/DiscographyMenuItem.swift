import AppKit
import Commands

/// The track menu's Show Discography item, filled each time the track menu opens for its
/// first selected track, since it is a plain item for one artist and a submenu for several
/// (ADR 0217).
@MainActor
final class DiscographyMenuItem: NSObject, NSMenuDelegate {
    var fill: (NSMenuItem) -> Void = { _ in }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let item = menu.item(withTitle: AppMenus.showDiscographyMenuTitle) else {
            preconditionFailure("the track menu has no \(AppMenus.showDiscographyMenuTitle)")
        }
        fill(item)
    }
}
