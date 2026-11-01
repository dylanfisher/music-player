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

    private let writer: TagWriter
    /// Bumped by each open, so a slow read for an earlier one is dropped.
    private var session = 0
    public private(set) var isBusy = false

    public init(writer: TagWriter) {
        self.writer = writer
    }

    public var isOpen: Bool { sheet != nil }
    public var canRemoveArt: Bool { sheet?.model.canRemoveArt == true }

    /// Reads `paths` and opens the editor over `window`.
    public func open(_ paths: [String], over window: NSWindow) {
        guard !paths.isEmpty, sheet == nil, !isBusy else { return }
        session += 1
        let token = session
        Task { [weak self] in
            let (tracks, problems) = await Task.detached { readEditableTracks(paths) }.value
            guard let self, token == self.session, self.sheet == nil, !self.isBusy else { return }
            if !problems.isEmpty {
                self.show(
                    "\(problems.count) of \(paths.count) files can't be edited", problems,
                    over: window)
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
            self.sheet = sheet
            sheet.begin(over: window)
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
                self?.show("The image couldn't be read", ["\(error)"], over: sheet.window)
            }
        }
    }

    public func removeArt() { sheet?.removeArt() }

    /// Undo Tag Edit: puts back the files of the newest edit.
    public func undo(over window: NSWindow) {
        guard !isBusy, sheet == nil else { return }
        run(over: window, "undo the tag edit") { $0.undoLast() }
    }

    private func confirm(_ edit: TagEdit, _ paths: [String], over window: NSWindow) {
        guard !edit.isEmpty else { return }
        let action = "write the tags"
        guard paths.count > 1 else {
            run(over: window, action) { $0.write(edit, to: paths) }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Change the tags of \(paths.count) files?"
        alert.informativeText =
            "Each file is rewritten with the new tags. Undo Tag Edit puts them all back."
        alert.addButton(withTitle: "Change Tags")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.run(over: window, action) { $0.write(edit, to: paths) }
        }
    }

    private func run(
        over window: NSWindow, _ action: String,
        _ work: @escaping @Sendable (TagWriter) -> TagWriteReport
    ) {
        isBusy = true
        let writer = writer
        Task {
            let report = await Task.detached { work(writer) }.value
            self.isBusy = false
            if !report.changed.isEmpty { self.written(report.changed) }
            if report.nothingToUndo, report.failures.isEmpty {
                NSSound.beep()
                logger.notice("no tag edit to undo")
            }
            if !report.failures.isEmpty {
                self.show(
                    "Couldn't \(action) for \(report.failures.count) file"
                        + (report.failures.count == 1 ? "" : "s"),
                    report.failures.map(\.description), over: window)
            }
        }
    }

    /// The problems in an alert, the first few in full.
    private func show(_ message: String, _ problems: [String], over window: NSWindow) {
        let shown = 8
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText =
            problems.prefix(shown).joined(separator: "\n")
            + (problems.count > shown ? "\n…and \(problems.count - shown) more" : "")
        alert.beginSheetModal(for: window)
    }
}
