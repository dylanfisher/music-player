import AppKit
import DisplayText

/// The button that adds a folder to the watched folders, in Add Folder…'s panel and here.
public let watchTitle = "Watch"

/// Asks over `window` for the folder the missing file `miss` lives under now, and answers with
/// it, or never on Cancel (ADR 0053).
@MainActor
func askForFolder(locating miss: String, over window: NSWindow, answer: @escaping (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Locate"
    panel.message =
        "Choose the folder that holds \(terminalSafe((miss as NSString).lastPathComponent)) now,"
        + " or a folder above it. The import's other misses under the same folder are matched"
        + " again too. Music files aren't touched."
    panel.beginSheetModal(for: window) { response in
        guard response == .OK, let url = panel.url else { return }
        answer(url)
    }
}

/// Asks over `window` whether to watch `folder`, which no watched folder holds, so its files
/// join the library and Locate… can match them; answers true for Watch.
@MainActor
func askToWatch(_ folder: String, over window: NSWindow, answer: @escaping (Bool) -> Void) {
    let alert = NSAlert()
    alert.messageText = "Watch “\(terminalSafe((folder as NSString).lastPathComponent))”?"
    alert.informativeText =
        "\(terminalSafe(folder)) isn't in a watched folder, so its files aren't in the library."
        + " Watch it, and the misses are matched again once its scan ends."
    alert.addButton(withTitle: watchTitle)
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
}
