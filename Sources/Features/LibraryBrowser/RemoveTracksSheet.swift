import AppKit

/// What Remove… does with the tracks the user confirmed (ADR 0050).
enum RemovalChoice: Equatable {
    /// Out of the library, and out of later scans until restored.
    case library
    /// Out of the library, with their files moved to the Trash.
    case trash
}

/// The sheet's question for `count` tracks.
func removalQuestion(count: Int) -> String {
    count == 1 ? "Remove Track?" : "Remove \(count) Tracks?"
}

/// Asks over `window` what to do with `count` tracks, and answers nil for Cancel. Cancel is the
/// first button, so Return and Escape both change nothing.
@MainActor
func askToRemove(
    _ count: Int, over window: NSWindow, answer: @escaping (RemovalChoice?) -> Void
) {
    let alert = NSAlert()
    alert.messageText = removalQuestion(count: count)
    alert.informativeText =
        "Remove from Library keeps the files where they are, and later scans skip them until"
        + " they're restored from Library Health. Remove and Move to Trash also moves the files"
        + " to the Trash."
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: ProblemAction.remove.title)
    alert.addButton(withTitle: "Remove and Move to Trash")
    alert.beginSheetModal(for: window) { response in
        switch response {
        case .alertSecondButtonReturn: answer(.library)
        case .alertThirdButtonReturn: answer(.trash)
        default: answer(nil)
        }
    }
}
