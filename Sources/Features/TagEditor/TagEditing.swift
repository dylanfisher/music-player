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
    /// Called on the main thread with what a write or undo changed, for the rescan.
    public var written: (TagWriteReport) -> Void = { _ in }
    /// Called on the main thread as a save goes, for the status bar: "Saving tags: 3 of 20" and
    /// how far along, from 0 to 1; nil once no write is left (ADR 0108).
    public var saving: (_ progress: (text: String, fraction: Double)?) -> Void = { _ in }
    /// What an info window's art buttons run: the registry's Replace Artwork… and Remove
    /// Artwork.
    public var replaceArtwork: () -> Void = {}
    public var removeArtwork: () -> Void = {}
    /// The top left corner the user last moved an info window to, where the next one opens;
    /// nil opens it near the main window's top left.
    public var place: NSPoint?
    /// Called when the user moves an info window, with its new top left corner, to save it.
    public var placeChanged: (NSPoint) -> Void = { _ in }

    /// What the editor does to the files and the screen, so tests can stand in for each.
    struct Effects {
        /// Reads the files for an info window; runs off the main thread, and stops starting
        /// files once its second argument says the window closed.
        var read:
            @Sendable ([String], @escaping @Sendable () -> Bool) -> (
                tracks: [EditableTrack], problems: [String]
            )
        /// Writes an edit, telling its last argument how far it's got, from any thread.
        var write:
            @Sendable (TagEdit, [String], @escaping @Sendable (TagWriteProgress) -> Void) ->
                TagWriteReport
        var undo: @Sendable () -> TagWriteReport
        /// Shows an info window in front, beside the main window: at the place given, past the
        /// other info windows' top left corners.
        var present: @MainActor (TagEditorWindow, NSWindow, NSPoint?, [NSPoint]) -> Void
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
    private(set) var pendingWrites = 0
    /// Where a finished write's failures are shown, by the write's number.
    private var alertWindows: [Int: (action: String, window: NSWindow)] = [:]
    private var lastWrite = 0
    /// Each open window's latest read, so an earlier read that comes back late is dropped.
    private var reads: [ObjectIdentifier: ReadStop] = [:]

    public init(writer: TagWriter) {
        effects = Effects(
            read: { readEditableTracks($0, isStopped: $1) },
            write: { writer.write($0, to: $1, progress: $2) }, undo: { writer.undoLast() },
            present: { $0.show(beside: $1, at: $2, avoiding: $3) }, confirm: ask,
            alert: showProblems)
        // A write in place a crash cut short is finished before anything reads the file
        // again; the writer logs what it found (ADR 0107).
        writes.async { [weak self] in
            let report = writer.recoverInterrupted()
            guard !report.changed.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.written(report) }
            }
        }
    }

    init(effects: Effects) {
        self.effects = effects
    }

    var isOpen: Bool { !editors.isEmpty }
    var isWriting: Bool { pendingWrites > 0 }

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
            present(open, over: window)
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
        editor.moved = { [weak self] corner in
            self?.place = corner
            self?.placeChanged(corner)
        }
        editors.append(editor)
        present(editor, over: window)
        read(into: editor, over: window)
    }

    private func present(_ editor: TagEditorWindow, over window: NSWindow) {
        let taken = editors.filter { $0 !== editor && $0.window.isVisible }.map(\.corner)
        effects.present(editor, window, place, taken)
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
        enqueue("undo the tag edit", over: window) { _ in undo() }
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
            enqueue("write the tags", over: window) { write(edit, paths, $0) }
            return
        }
        effects.confirm(.writing(paths.count), editor.window) { [weak self, weak editor] yes in
            guard yes, let self else { return }
            editor?.close()
            self.enqueue("write the tags", over: window) { write(edit, paths, $0) }
        }
    }

    /// Queues `work`, which is handed what to tell of its progress.
    private func enqueue(
        _ action: String, over window: NSWindow,
        _ work:
            @escaping @Sendable (@escaping @Sendable (TagWriteProgress) -> Void) ->
            TagWriteReport
    ) {
        lastWrite += 1
        let number = lastWrite
        alertWindows[number] = (action, window)
        pendingWrites += 1
        writes.async {
            let report = work { progress in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.saving(Self.savingStatus(progress)) }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finished(number, report) }
            }
        }
    }

    /// "Saving tags: 3 of 20", by the files written, and how far along.
    static func savingStatus(_ progress: TagWriteProgress) -> (text: String, fraction: Double) {
        let count = { (value: Int) in
            NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
        }
        return (
            "Saving tags: \(count(progress.written)) of \(count(progress.total))",
            progress.fraction
        )
    }

    private func finished(_ number: Int, _ report: TagWriteReport) {
        pendingWrites -= 1
        if pendingWrites == 0 { saving(nil) }
        guard let (action, window) = alertWindows.removeValue(forKey: number) else { return }
        if !report.changed.isEmpty {
            written(report)
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
