import AppKit
import Log
import Metadata
import TagWriter
import UniformTypeIdentifiers

private let logger = moduleLogger()

/// Opens info windows on the selected files, writes what the user saves, and undoes the last
/// edit. Get Info opens a window at once, whatever else is open or being written, and fills it
/// in when its files are read (ADR 0100). Reads run off the main thread; writes and undos run
/// one at a time, in the order asked, on a queue of their own, since NAS files are slow.
/// Nothing is written until the user saves, and confirms when it's more than one file.
@MainActor
public final class TagEditing {
    /// The info windows open, in the order they opened.
    public private(set) var editors: [TagEditorWindow] = []
    /// Called on the main thread with the files a write or undo changed, for the rescan.
    public var written: ([String]) -> Void = { _ in }
    /// What an info window's art buttons run: the registry's Replace Artwork… and Remove
    /// Artwork.
    public var replaceArtwork: () -> Void = {}
    public var removeArtwork: () -> Void = {}

    /// What the editor does to the files and the screen, so tests can stand in for each.
    struct Effects {
        /// Reads the files for an info window; runs off the main thread, and stops starting
        /// files once its second argument says the window closed.
        var read:
            @Sendable ([String], @escaping @Sendable () -> Bool) -> (
                tracks: [EditableTrack], problems: [String]
            )
        var write: @Sendable (TagEdit, [String]) -> TagWriteReport
        var undo: @Sendable () -> TagWriteReport
        /// Shows an info window in front, beside the main window.
        var present: @MainActor (TagEditorWindow, NSWindow) -> Void
        /// Asks before a batch write, then calls back with the answer.
        var confirm:
            @MainActor (Confirmation, NSWindow, @escaping @MainActor (Bool) -> Void) -> Void
        var alert: @MainActor (String, [String], NSWindow) -> Void
    }

    /// A question the user answers before the editor writes a batch of files.
    struct Confirmation: Equatable {
        var message: String
        var detail: String
        var button: String

        static func writing(_ count: Int) -> Confirmation {
            Confirmation(
                message: "Change the tags of \(count) files?",
                detail:
                    "Each file is rewritten with the new tags. Undo Tag Edit puts them all back.",
                button: "Change Tags")
        }
    }

    private let effects: Effects
    /// Writes and undos, one at a time in the order asked.
    private let writes = DispatchQueue(
        label: "\(bundleIdentifier).tag-writes", qos: .userInitiated)
    /// Writes and undos asked for and not yet finished.
    public private(set) var pendingWrites = 0
    /// Where a finished write's failures are shown, by the write's number.
    private var alertWindows: [Int: (action: String, window: NSWindow)] = [:]
    private var lastWrite = 0
    /// Each open window's latest read, so an earlier read that comes back late is dropped.
    private var reads: [ObjectIdentifier: ReadStop] = [:]

    public init(writer: TagWriter) {
        effects = Effects(
            read: { readEditableTracks($0, isStopped: $1) },
            write: { writer.write($0, to: $1) }, undo: { writer.undoLast() },
            present: { $0.show(beside: $1) }, confirm: ask, alert: showProblems)
    }

    init(effects: Effects) {
        self.effects = effects
    }

    public var isOpen: Bool { !editors.isEmpty }
    public var isWriting: Bool { pendingWrites > 0 }

    /// The info window the art commands act on: the key one, else the last opened.
    var active: TagEditorWindow? {
        editors.last { $0.window.isKeyWindow } ?? editors.last
    }

    public var canReplaceArt: Bool { active?.isLoaded == true }
    public var canRemoveArt: Bool { active?.model?.canRemoveArt == true }

    /// Get Info: opens an info window on `paths` at once and reads them into it. A window
    /// already open on the same tracks comes to the front instead.
    public func open(_ paths: [String], over window: NSWindow) {
        guard !paths.isEmpty else { return }
        if let open = editors.first(where: { $0.paths == paths }) {
            effects.present(open, window)
            return
        }
        let editor = TagEditorWindow(paths: paths)
        editor.replaceArtwork = { [weak self] in self?.replaceArtwork() }
        editor.removeArtwork = { [weak self] in self?.removeArtwork() }
        editor.saved = { [weak self, weak editor] edit in
            guard let self, let editor else { return }
            self.save(edit, from: editor, over: window)
        }
        editor.closed = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.editors.removeAll { $0 === editor }
            self.reads.removeValue(forKey: ObjectIdentifier(editor))?.stop()
        }
        editors.append(editor)
        effects.present(editor, window)
        read(into: editor, over: window)
    }

    /// Reads the window's files and shows them in it; a window that already shows them keeps
    /// what was typed.
    private func read(into editor: TagEditorWindow, over window: NSWindow) {
        let key = ObjectIdentifier(editor)
        reads[key]?.stop()
        let stop = ReadStop()
        reads[key] = stop
        let read = effects.read
        let paths = editor.paths
        Task { [weak self, weak editor] in
            let (tracks, problems) = await blockingFileWork { read(paths) { stop.isStopped } }
            guard let self, let editor, self.reads[key] === stop else { return }
            self.reads[key] = nil
            if let model = editor.model {
                guard problems.isEmpty, tracks.map(\.path) == model.tracks.map(\.path) else {
                    logger.error(
                        "couldn't read the files of an info window again: \(problems.joined(separator: "; "))"
                    )
                    return
                }
                editor.load(TagEditorModel(tracks: tracks))
                return
            }
            guard !tracks.isEmpty else {
                editor.close()
                self.effects.alert(
                    "\(problems.count) of \(paths.count) files can't be edited", problems, window)
                return
            }
            editor.load(TagEditorModel(tracks: tracks))
            if !problems.isEmpty {
                self.effects.alert(
                    "\(problems.count) of \(paths.count) files can't be edited", problems,
                    editor.window)
            }
        }
    }

    /// Replace Artwork…: an image chosen in an open panel over the info window.
    public func chooseArt() {
        guard let editor = active, editor.isLoaded else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.message = "Choose a JPEG or PNG image for the artwork."
        panel.beginSheetModal(for: editor.window) { [weak self, weak editor] response in
            guard response == .OK, let url = panel.url, let editor else { return }
            do {
                let image = try Data(contentsOf: url)
                let type = UTType(filenameExtension: url.pathExtension)
                editor.replaceArt(image, mimeType: type == .png ? pngMIMEType : jpegMIMEType)
            } catch {
                self?.effects.alert("The image couldn't be read", ["\(error)"], editor.window)
            }
        }
    }

    public func removeArt() { active?.removeArt() }

    /// Undo Tag Edit: puts back the files of the newest edit, after any write still queued.
    public func undo(over window: NSWindow) {
        let undo = effects.undo
        enqueue("undo the tag edit", over: window) { undo() }
    }

    /// Writes one file at once; a batch asks first, in a sheet on the info window, which stays
    /// open with what was typed if the answer is no. The window closes once the write is
    /// queued.
    private func save(_ edit: TagEdit, from editor: TagEditorWindow, over window: NSWindow) {
        guard let model = editor.model else { return }
        if let note = model.collapseNote { logger.notice("\(note)") }
        let paths = model.tracks.map(\.path)
        guard !edit.isEmpty else {
            editor.close()
            return
        }
        let write = effects.write
        guard paths.count > 1 else {
            editor.close()
            enqueue("write the tags", over: window) { write(edit, paths) }
            return
        }
        effects.confirm(.writing(paths.count), editor.window) { [weak self, weak editor] yes in
            guard yes, let self else { return }
            editor?.close()
            self.enqueue("write the tags", over: window) { write(edit, paths) }
        }
    }

    private func enqueue(
        _ action: String, over window: NSWindow,
        _ work: @escaping @Sendable () -> TagWriteReport
    ) {
        lastWrite += 1
        let number = lastWrite
        alertWindows[number] = (action, window)
        pendingWrites += 1
        writes.async {
            let report = work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finished(number, report) }
            }
        }
    }

    private func finished(_ number: Int, _ report: TagWriteReport) {
        pendingWrites -= 1
        guard let (action, window) = alertWindows.removeValue(forKey: number) else { return }
        if !report.changed.isEmpty {
            written(report.changed)
            let changed = Set(report.changed)
            for editor in editors where !changed.isDisjoint(with: editor.paths) {
                read(into: editor, over: window)
            }
        }
        if report.nothingToUndo, report.failures.isEmpty {
            NSSound.beep()
            logger.notice("no tag edit to undo")
        }
        if !report.failures.isEmpty {
            let skipped =
                report.notWritten.isEmpty
                ? [] : ["The rest stopped: \(report.notWritten.count) files weren't written."]
            effects.alert(
                "Couldn't \(action) for \(report.failures.count) file"
                    + (report.failures.count == 1 ? "" : "s"),
                report.failures.map(\.description) + skipped, window)
        }
    }
}

/// Set when an info window closes or reads its files again, so the read it started stops
/// starting files and its result is dropped.
private final class ReadStop: @unchecked Sendable {
    // `stopped` is guarded by `lock`.
    private let lock = NSLock()
    private var stopped = false

    func stop() { lock.withLock { stopped = true } }
    var isStopped: Bool { lock.withLock { stopped } }
}

/// The problems in an alert, the first few in full.
@MainActor
private func showProblems(_ message: String, _ problems: [String], over window: NSWindow) {
    let shown = 8
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText =
        problems.prefix(shown).joined(separator: "\n")
        + (problems.count > shown ? "\n…and \(problems.count - shown) more" : "")
    alert.beginSheetModal(for: window)
}

@MainActor
private func ask(
    _ question: TagEditing.Confirmation, over window: NSWindow,
    _ answer: @escaping @MainActor (Bool) -> Void
) {
    let alert = NSAlert()
    alert.messageText = question.message
    alert.informativeText = question.detail
    alert.addButton(withTitle: question.button)
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
}
