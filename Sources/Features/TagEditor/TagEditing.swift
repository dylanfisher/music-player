import AppKit
import Log
import Metadata
import TagWriter
import UniformTypeIdentifiers

private let logger = moduleLogger()

/// Opens the tag editor on the selected files, writes what the user saves, and undoes the last
/// edit. Reading and writing run off the main thread, one write at a time, since NAS files are
/// slow. Nothing is written until the user saves, and confirms when it's more than one file.
@MainActor
public final class TagEditing {
    /// The editor while it's open.
    public private(set) var sheet: TagEditorSheet?
    /// Called on the main thread with the files a write or undo changed, for the rescan.
    public var written: ([String]) -> Void = { _ in }
    /// What the sheet's art buttons run: the registry's Replace Artwork… and Remove Artwork.
    public var replaceArtwork: () -> Void = {}
    public var removeArtwork: () -> Void = {}

    /// What the editor does to the files and the screen, so tests can stand in for each.
    struct Effects {
        /// Reads the files for the editor; runs off the main thread.
        var read: @Sendable ([String]) -> (tracks: [EditableTrack], problems: [String])
        var write: @Sendable (TagEdit, [String]) -> TagWriteReport
        var undo: @Sendable () -> TagWriteReport
        var present: @MainActor (TagEditorSheet, NSWindow) -> Void
        /// Asks before a batch write or a big read, then calls back with the answer.
        var confirm:
            @MainActor (Confirmation, NSWindow, @escaping @MainActor (Bool) -> Void) -> Void
        var alert: @MainActor (String, [String], NSWindow) -> Void
    }

    /// A question the user answers before the editor reads or writes a batch of files.
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

        static func reading(_ count: Int) -> Confirmation {
            Confirmation(
                message: "Read the tags of \(count) files?",
                detail: "Reading the tags of \(count) files may take minutes on a network share.",
                button: "Read Tags")
        }
    }

    /// Get Info on more files than this asks first. The editor reads every file before it
    /// opens, and the 2015 MacBook Pro takes 129 ms a file on the slow simulated NAS, so 25
    /// files open in about 3 s there; the whole library takes minutes (ADR 0081).
    static let confirmReadAbove = 25

    private let effects: Effects
    /// Bumped by each open, so a slow read for an earlier one is dropped.
    private var session = 0
    public private(set) var isBusy = false

    public init(writer: TagWriter) {
        effects = Effects(
            read: { readEditableTracks($0) }, write: { writer.write($0, to: $1) },
            undo: { writer.undoLast() }, present: { $0.begin(over: $1) },
            confirm: ask, alert: showProblems)
    }

    init(effects: Effects) {
        self.effects = effects
    }

    public var isOpen: Bool { sheet != nil }
    public var canRemoveArt: Bool { sheet?.model.canRemoveArt == true }

    /// Reads `paths` and opens the editor over `window`.
    public func open(_ paths: [String], over window: NSWindow) {
        guard !paths.isEmpty, sheet == nil, !isBusy else { return }
        guard paths.count > Self.confirmReadAbove else {
            read(paths, over: window)
            return
        }
        effects.confirm(.reading(paths.count), window) { [weak self] yes in
            if yes { self?.read(paths, over: window) }
        }
    }

    private func read(_ paths: [String], over window: NSWindow) {
        guard sheet == nil, !isBusy else { return }
        session += 1
        let token = session
        Task { [weak self] in
            let read = self?.effects.read
            guard let read else { return }
            let (tracks, problems) = await blockingFileWork { read(paths) }
            guard let self, token == self.session, self.sheet == nil, !self.isBusy else { return }
            if !problems.isEmpty {
                self.effects.alert(
                    "\(problems.count) of \(paths.count) files can't be edited", problems, window)
            }
            guard !tracks.isEmpty else { return }
            let sheet = TagEditorSheet(model: TagEditorModel(tracks: tracks))
            sheet.replaceArtwork = { [weak self] in self?.replaceArtwork() }
            sheet.removeArtwork = { [weak self] in self?.removeArtwork() }
            sheet.saved = { [weak self, weak sheet] edit in
                if let note = sheet?.model.collapseNote { logger.notice("\(note)") }
                self?.sheet = nil
                self?.confirm(edit, tracks.map(\.path), over: window)
            }
            sheet.cancelled = { [weak self] in self?.sheet = nil }
            self.sheet = sheet
            self.effects.present(sheet, window)
        }
    }

    /// Replace Artwork…: an image chosen in an open panel over the editor.
    public func chooseArt() {
        guard let sheet else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.message = "Choose a JPEG or PNG image for the artwork."
        panel.beginSheetModal(for: sheet.window) { [weak self, weak sheet] response in
            guard response == .OK, let url = panel.url, let sheet else { return }
            do {
                let image = try Data(contentsOf: url)
                let type = UTType(filenameExtension: url.pathExtension)
                sheet.replaceArt(image, mimeType: type == .png ? pngMIMEType : jpegMIMEType)
            } catch {
                self?.effects.alert("The image couldn't be read", ["\(error)"], sheet.window)
            }
        }
    }

    public func removeArt() { sheet?.removeArt() }

    /// Undo Tag Edit: puts back the files of the newest edit.
    public func undo(over window: NSWindow) {
        guard !isBusy, sheet == nil else { return }
        let undo = effects.undo
        run(over: window, "undo the tag edit") { undo() }
    }

    private func confirm(_ edit: TagEdit, _ paths: [String], over window: NSWindow) {
        guard !edit.isEmpty else { return }
        let action = "write the tags"
        let write = effects.write
        guard paths.count > 1 else {
            run(over: window, action) { write(edit, paths) }
            return
        }
        effects.confirm(.writing(paths.count), window) { [weak self] yes in
            guard yes else { return }
            self?.run(over: window, action) { write(edit, paths) }
        }
    }

    private func run(
        over window: NSWindow, _ action: String,
        _ work: @escaping @Sendable () -> TagWriteReport
    ) {
        isBusy = true
        Task {
            let report = await Task.detached { work() }.value
            self.isBusy = false
            if !report.changed.isEmpty { self.written(report.changed) }
            if report.nothingToUndo, report.failures.isEmpty {
                NSSound.beep()
                logger.notice("no tag edit to undo")
            }
            if !report.failures.isEmpty {
                let skipped =
                    report.notWritten.isEmpty
                    ? [] : ["The rest stopped: \(report.notWritten.count) files weren't written."]
                self.effects.alert(
                    "Couldn't \(action) for \(report.failures.count) file"
                        + (report.failures.count == 1 ? "" : "s"),
                    report.failures.map(\.description) + skipped, window)
            }
        }
    }

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
