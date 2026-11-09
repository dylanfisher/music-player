import AppKit
import Commands
import Library

/// The files Edit ▸ Copy last copied, and the pasteboard's change count once it wrote their
/// text. The pasteboard holds text only, so Paste finds the files here, and only while the
/// pasteboard still holds that copy (ADR 0161).
struct TrackClipboard: Equatable {
    var paths: [String]
    var changeCount: Int

    /// The copied paths, or nil once anything else was put on the pasteboard.
    func paths(atChangeCount current: Int) -> [String]? {
        current == changeCount ? paths : nil
    }
}

/// The list Edit ▸ Copy, Paste and Delete act on: the queue when it has the keys, else the
/// track lists. None while another window is key, where they'd act on a selection out of sight.
enum EditList: Equatable {
    case queue, tracks
}

func editList(mainWindowKey: Bool, queueHasKeys: Bool) -> EditList? {
    guard mainWindowKey else { return nil }
    return queueHasKeys ? .queue : .tracks
}

/// Edit ▸ Copy, Paste and Delete for the track lists and the queue. They're standard items, so
/// a text field's editor takes them first; these answer when a list has the keys.
extension AppDelegate: NSMenuItemValidation {
    @objc func copy(_ sender: Any?) {
        guard let list = currentEditList else { return }
        if list == .queue, let queue {
            writeCopies(queue.selectedCopies())
            return
        }
        guard let browser, browser.canCopySelection else { return }
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
        switch currentEditList {
        case .queue: addToQueue(paths.map { URL(fileURLWithPath: $0, isDirectory: false) })
        case .tracks where browser?.canPaste == true: browser?.paste(paths)
        case .tracks, nil: NSSound.beep()
        }
    }

    /// Takes the selection out of the queue or the playlist shown, as Remove from Queue or
    /// Playlist does; never from the library.
    @objc func delete(_ sender: Any?) {
        if currentEditList == nil || dispatcher?.run(.removeFromQueue) != true { NSSound.beep() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            switch currentEditList {
            case .queue: queue?.hasSelection == true
            case .tracks: browser?.canCopySelection == true
            case nil: false
            }
        case #selector(paste(_:)):
            pastedPaths != nil
                && (currentEditList == .queue
                    || (currentEditList == .tracks && browser?.canPaste == true))
        case #selector(delete(_:)):
            currentEditList != nil && dispatcher?.isEnabled(.removeFromQueue) == true
        default: true
        }
    }

    private var currentEditList: EditList? {
        guard let window else { return nil }
        return editList(
            mainWindowKey: NSApp.keyWindow === window.window,
            queueHasKeys: queue.map { window.window.firstResponder === $0.list } ?? false)
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
