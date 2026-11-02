import AppKit
import DisplayText
import Library

/// Asks over `window` which removed tracks to restore, from a menu of their paths, as the Lost
/// Stats sheet offers its tracks. Answers the IDs to restore: the one picked, every one, or
/// none for Cancel.
@MainActor
func askToRestore(
    _ removed: [RemovedPath], over window: NSWindow, answer: @escaping ([Int64]) -> Void
) {
    let alert = NSAlert()
    alert.messageText = "Restore Removed Tracks"
    alert.informativeText =
        "\(removed.count == 1 ? "1 track was" : "\(removed.count) tracks were") removed from the"
        + " library. A restored track comes back when its folder is scanned, which starts now."
    alert.addButton(withTitle: ProblemAction.restore.title)
    alert.addButton(withTitle: "Restore All")
    alert.addButton(withTitle: "Cancel")
    let paths = NSPopUpButton()
    for item in removed {
        paths.addItem(withTitle: terminalSafe(item.path))
        paths.lastItem?.tag = Int(item.id)
    }
    paths.frame = NSRect(
        x: 0, y: 0, width: LostStatsSheet.width, height: paths.fittingSize.height)
    alert.accessoryView = paths
    alert.beginSheetModal(for: window) { response in
        switch response {
        case .alertFirstButtonReturn: answer([Int64(paths.selectedTag())])
        case .alertSecondButtonReturn: answer(removed.map(\.id))
        default: answer([])
        }
    }
}
