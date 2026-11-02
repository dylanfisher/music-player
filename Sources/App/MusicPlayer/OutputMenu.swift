import AppKit
import Settings

/// Controls ▸ Output: the outputs found, listed again each time it opens, the one in use
/// checked.
@MainActor
final class OutputMenu: NSObject, NSMenuDelegate {
    /// The outputs to list, and the one in use.
    var options: () -> (options: [OutputOption], current: OutputChoice) = { ([], .systemDefault) }
    var choose: (OutputChoice) -> Void = { _ in }
    /// Called as the menu opens, to search for renderers.
    var opened: () -> Void = {}
    private weak var openMenu: NSMenu?

    func menuNeedsUpdate(_ menu: NSMenu) { fill(menu) }

    func menuWillOpen(_ menu: NSMenu) {
        openMenu = menu
        opened()
    }

    func menuDidClose(_ menu: NSMenu) { openMenu = nil }

    /// Lists the outputs again in the menu while it's open, after a search found more.
    func refresh() {
        openMenu.map(fill)
    }

    func fill(_ menu: NSMenu) {
        let (options, current) = options()
        menu.removeAllItems()
        for option in options {
            let item = NSMenuItem(
                title: option.title, action: #selector(chose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.choice.text
            item.state = option.choice == current ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func chose(_ item: NSMenuItem) {
        guard let text = item.representedObject as? String, let choice = OutputChoice(text: text)
        else { return }
        choose(choice)
    }
}
