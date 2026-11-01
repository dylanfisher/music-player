import AppKit
import DisplayText
import Library
import Settings

/// One lost file at a time, as an `NSAlert` sheet (ADR 0012): its path, and a menu of the
/// tracks that match it to give its stats to. Each answer is written, then the next file shows.
@MainActor
final class LostStatsSheet {
    /// Called after each file's stats move or it's dismissed.
    var changed: () -> Void = {}
    var failed: (String) -> Void = { _ in }
    /// Called when the last sheet closes.
    var closed: () -> Void = {}

    private let session: LostStatsSession
    private(set) var alert = NSAlert()
    let candidates = NSPopUpButton()

    /// Wide enough for a NAS path in the menu without truncating most of them.
    static let width = 640.0

    init(session: LostStatsSession) {
        self.session = session
    }

    func begin(over window: NSWindow) {
        guard let file = session.current else { return closed() }
        alert = NSAlert()
        alert.messageText = HealthCheck.lostStats.title
        alert.informativeText =
            terminalSafe(file.path)
            + " left the library with plays, a rating or playlist entries. Give them to a track"
            + " that matches it, or dismiss it. Music files aren't touched."
        alert.addButton(withTitle: "Give Stats")
        alert.addButton(withTitle: "Dismiss")
        alert.addButton(withTitle: "Later")
        candidates.removeAllItems()
        for id in file.candidates {
            candidates.addItem(
                withTitle: terminalSafe(session.paths[id] ?? "a track that left the library"))
            candidates.lastItem?.tag = Int(id)
        }
        if file.candidates.isEmpty { candidates.addItem(withTitle: "No track matches it") }
        candidates.isEnabled = !file.candidates.isEmpty
        alert.buttons[0].isEnabled = !file.candidates.isEmpty
        candidates.frame = NSRect(
            x: 0, y: 0, width: Self.width, height: candidates.fittingSize.height)
        alert.accessoryView = candidates
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let track = Int64(candidates.selectedTag())
            Task { await self.answer(response, track: track, window: window) }
        }
    }

    private func answer(_ response: NSApplication.ModalResponse, track: Int64, window: NSWindow)
        async
    {
        do {
            switch response {
            case .alertFirstButtonReturn: try await session.pick(track)
            case .alertSecondButtonReturn: try await session.dismissShown()
            default: return closed()
            }
            changed()
        } catch {
            failed("couldn't resolve the lost stats: \(error)")
            return closed()
        }
        begin(over: window)
    }
}
