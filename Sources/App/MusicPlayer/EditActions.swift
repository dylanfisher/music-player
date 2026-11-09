import AppKit
import Commands
import Library

/// The files Edit ▸ Copy last copied, and the pasteboard's change count once it wrote their
/// text. The pasteboard holds text only, so Paste finds the files here, and only while the
/// pasteboard still holds that copy (ADR 0160).
struct TrackClipboard: Equatable {
    var paths: [String]
    var changeCount: Int

    /// The copied paths, or nil once anything else was put on the pasteboard.
    func paths(atChangeCount current: Int) -> [String]? {
        current == changeCount ? paths : nil
    }
}

enum PasteTarget: Equatable {
    case queue, playlist
}

/// Where Edit ▸ Paste adds tracks: the queue when it has the keys, the manual playlist shown
/// when the track table has them, and nowhere else, the library least of all.
func pasteTarget(queueFocused: Bool, canPasteInPlaylist: Bool) -> PasteTarget? {
    if queueFocused { return .queue }
    return canPasteInPlaylist ? .playlist : nil
}

/// Edit ▸ Copy, Paste and Delete for the track lists and the queue. They're standard items, so
/// a text field's editor takes them first; these answer when a list has the keys.
extension AppDelegate: NSMenuItemValidation {
    @objc func copy(_ sender: Any?) {
        guard let browser, isMainWindowKey else { return }
        if queueHasKeys, let queue {
            writeCopies(queue.selectedCopies())
            return
        }
        guard browser.canCopySelection else { return }
        Task {
            do {
                writeCopies(try await browser.selectedCopies())
            } catch {
                browser.reportCommand("couldn't copy the tracks", error)
            }
        }
    }

    @objc func paste(_ sender: Any?) {
        guard let paths = pastedPaths else {
            NSSound.beep()
            return
        }
        switch currentPasteTarget {
        case .queue: queue?.paste(paths)
        case .playlist: browser?.paste(paths)
        case nil: NSSound.beep()
        }
    }

    /// Takes the selection out of the queue or the playlist shown, as Remove from Queue or
    /// Playlist does; never from the library.
    @objc func delete(_ sender: Any?) {
        if dispatcher?.run(.removeFromQueue) != true { NSSound.beep() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            isMainWindowKey
                && (queueHasKeys
                    ? queue?.hasSelection == true : browser?.canCopySelection == true)
        case #selector(paste(_:)): pastedPaths != nil && currentPasteTarget != nil
        case #selector(delete(_:)): dispatcher?.isEnabled(.removeFromQueue) == true
        default: true
        }
    }

    private var isMainWindowKey: Bool {
        window.map { NSApp.keyWindow === $0.window } ?? false
    }

    private var queueHasKeys: Bool {
        guard let window, let queue else { return false }
        return window.window.firstResponder === queue.list
    }

    private var currentPasteTarget: PasteTarget? {
        guard isMainWindowKey else { return nil }
        return pasteTarget(
            queueFocused: queueHasKeys, canPasteInPlaylist: browser?.canPaste == true)
    }

    private var pastedPaths: [String]? {
        trackClipboard?.paths(atChangeCount: NSPasteboard.general.changeCount)
    }

    private func writeCopies(_ tracks: [CopiedTrack]) {
        guard !tracks.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(CopiedTrack.text(tracks), forType: .string)
        trackClipboard = TrackClipboard(
            paths: tracks.map(\.path), changeCount: pasteboard.changeCount)
    }
}
