import AppKit
import Commands
import Discogs
import Library
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
    /// Called on the main thread with what a write or undo changed, for the rescan, and what
    /// Keep Files Organized moved after it, whose files the report has at their new paths. The
    /// last argument is called once the library has the moves, which a Discogs write's
    /// completion waits for (ADR 0186).
    public var written: (TagWriteReport, FilesOrganized?, @escaping @MainActor () -> Void) -> Void =
        { _, _, done in done() }
    /// The library folder while Keep Files Organized is on, else nil, read as each write or
    /// undo the user asked for is queued (ADR 0164).
    public var organizingFolder: () -> String? = { nil }
    /// Called on the main thread as a save goes, for the status bar: "Saving tags: 3 of 20" and
    /// how far along, from 0 to 1, over every write queued and running (ADR 0167); nil once no
    /// write is left (ADR 0108).
    public var saving: (_ progress: (text: String, fraction: Double)?) -> Void = { _ in }
    /// Called on the main thread as Keep Files Organized or Organize Selected Files renames
    /// files, for the status bar (ADR 0175).
    public var organizing: (OrganizeProgress) -> Void = { _ in }
    /// Runs one of the registry's tag commands as its menu item does: an info window's Undo
    /// Tag Edit, Replace Artwork… and Remove Artwork buttons.
    public var run: (CommandID) -> Void = { _ in }
    /// Whether the registry enables a tag command now, for one that isn't about an info window:
    /// Undo Tag Edit. Its button follows it, as the menu item does.
    public var isEnabled: (CommandID) -> Bool = { _ in false }
    /// Whether the journal holds an edit to undo, which Undo Tag Edit's rule reads, so a menu
    /// validation never reads the journal folder. It's read again off the main thread at
    /// launch and after every write and undo finishes, from any window. Until the first read,
    /// and after a read that failed, it's true: Undo Tag Edit stays on and a click shows why.
    public private(set) var canUndo = true
    /// The play count the index has for each path, nil for one it has no track for, for the
    /// File tab's Plays field.
    public var playCounts: @MainActor ([String]) -> [Int?] = { $0.map { _ in nil } }
    /// Stores a play count typed in an info window for the tracks at the paths, in the index,
    /// once the window's Save goes ahead (ADR 0162).
    public var setPlayCount: @MainActor (Int, [String]) -> Void = { _, _ in }
    /// Reads a release from the local catalog for an info window's Discogs tab: nil when the
    /// catalog doesn't have it, and `CatalogError.missing` when there's no catalog.
    public var release: @MainActor (Int) async throws -> ReleaseDetail? = { _ in nil }

    /// What the editor does to the files and the screen, so tests can stand in for each.
    struct Effects {
        /// Reads the files for an info window; runs off the main thread, and stops starting
        /// files once its second argument says the window closed.
        var read:
            @Sendable ([String], @escaping @Sendable () -> Bool) -> (
                tracks: [EditableTrack], problems: [String]
            )
        /// Writes each file its edit, as made in the window the origin names, telling its last
        /// argument how far it's got, from any thread.
        var write:
            @Sendable (
                [(path: String, edit: TagEdit)], TagEditOrigin,
                @escaping @Sendable (TagWriteProgress) -> Void
            ) -> TagWriteReport
        /// Undoes the newest edit while it is still the one given, nil for none.
        var undo: @Sendable (JournaledEdit?) -> TagWriteReport
        /// The newest edit, nil with none to undo.
        var newestEdit: @Sendable () throws(TagWriteError) -> JournaledEdit?
        /// Shows an info window in front: at the frame info windows keep, or cascaded from the
        /// last other one open.
        var present: @MainActor (TagEditorWindow, NSWindow?) -> Void
        /// Asks before a batch write, then calls back with the answer.
        var confirm:
            @MainActor (Confirmation, NSWindow, @escaping @MainActor (Bool) -> Void) -> Void
        var alert: @MainActor (String, [String], NSWindow) -> Void
        /// Where files go in the library folder, the second argument, by its layout.
        var layout: @Sendable ([String], String) -> FilesOrganized
        /// Renames a plan's files in the library folder, the second argument; with the third,
        /// each is checked first to still go where the plan says. The last is told how far it
        /// has got, from the write queue.
        var move:
            @Sendable (FilesOrganized, String, Bool, (OrganizeProgress) -> Void) ->
                FilesOrganized
        /// Points the journal's records of each renamed file at its new path, giving what
        /// couldn't be.
        var follow: @Sendable ([TrackMove]) -> [TagWriteError]
        /// Asks what to do about quitting with the given number of writes and undos not
        /// finished, then calls back with the answer.
        var askQuit: @MainActor (Int, @escaping @MainActor (QuitAnswer) -> Void) -> Void
    }

    /// What the user chose when quitting with tag writes not finished (ADR 0167).
    enum QuitAnswer {
        /// Quit once the queue is empty.
        case waitAndQuit
        case quitAnyway
        case cancel
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

        /// Asked in place of `writing` when the batch gives every file the title `title`,
        /// usually a mistake made by editing a multiple selection.
        static func sameTitle(_ title: String, _ count: Int) -> Confirmation {
            Confirmation(
                message: "Give all \(count) tracks the title “\(title)”?",
                detail:
                    "Every track gets the same title, which is usually a slip made while editing"
                    + " several tracks at once. Undo Tag Edit puts them all back.",
                button: "Use One Title")
        }

        /// Asked when the newest edit, which Undo Tag Edit undoes, was made in another window.
        static func undoing(_ origin: TagEditOrigin, _ count: Int) -> Confirmation {
            let made =
                switch origin {
                case .tagEditor: "an info window's"
                case .discogsTagger: "the Discogs tagger's"
                }
            return Confirmation(
                message: "Undo \(made) edit of \(count) file\(count == 1 ? "" : "s")?",
                detail:
                    "Undo Tag Edit undoes the newest tag edit, which wasn't made in this window."
                    + " Its files get back the tags they had before it.",
                button: AppCommands.title(of: .undoTagEdit))
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
    /// What to tell a Discogs write's caller, by write number.
    private var completions: [Int: (Set<String>) -> Void] = [:]
    /// What to tell a Discogs write's caller of its progress, by write number.
    private var progresses: [Int: (TagWriteProgress) -> Void] = [:]
    /// What to tell a Discogs write's caller of Keep Files Organized's steps after it, by write
    /// number.
    private var organizeSteps: [Int: (OrganizeStep) -> Void] = [:]
    /// The writes queued, running and finished since the queue was last empty, by write number:
    /// how many files each writes, and its last report, nil before its first. Cleared when the
    /// queue drains, so the status bar's count never falls back.
    private var batches: [Int: (files: Int, progress: TagWriteProgress?)] = [:]
    private var lastWrite = 0
    /// Each open window's latest read, so an earlier read that comes back late is dropped.
    private var reads: [ObjectIdentifier: ReadStop] = [:]

    /// `ledger` is the library's index, where the files' moves are recorded until their stats
    /// follow them (ADR 0164).
    public init(writer: TagWriter, ledger: URL) {
        effects = Effects(
            read: { readEditableTracks($0, isStopped: $1) },
            write: { writer.write($0, origin: $1, progress: $2) },
            undo: { writer.undoLast(ifNewestIs: $0) },
            newestEdit: { () throws(TagWriteError) in try writer.newestEdit() },
            present: { $0.show(after: $1) }, confirm: ask,
            alert: showProblems,
            layout: { layoutMoves($0, libraryFolder: $1) },
            move: {
                moveToLayout(
                    $0, libraryFolder: $1, checkingAgain: $2, ledger: ledger, progress: $3)
            },
            follow: { writer.follow($0.map { ($0.from, $0.to) }) },
            askQuit: askToQuit)
        // A write in place a crash cut short is finished before anything reads the file
        // again; the writer logs what it found (ADR 0107).
        writes.async { [weak self] in
            let report = writer.recoverInterrupted()
            guard !report.changed.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.written(report, nil) {} }
            }
        }
        readCanUndo()
    }

    init(effects: Effects) {
        self.effects = effects
        readCanUndo()
    }

    /// Reads `canUndo` from the journal after the writes queued before it, then refreshes the
    /// info windows' buttons; the menu item asks when it's shown.
    private func readCanUndo() {
        let newestEdit = effects.newestEdit
        writes.async { [weak self] in
            let newest = Result { () throws(TagWriteError) in try newestEdit() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch newest {
                    case .success(let edit): self.canUndo = edit != nil
                    case .failure(let error):
                        logger.error("couldn't read the tag edit journal: \(error)")
                        self.canUndo = true
                    }
                    self.refreshCommands()
                }
            }
        }
    }

    var isOpen: Bool { !editors.isEmpty }
    var isWriting: Bool { pendingWrites > 0 }

    /// Called once the queue is empty, after Wait and Quit.
    private var quitWhenDone: (@MainActor () -> Void)?

    /// Holds a quit while tag writes or undos are queued or running (ADR 0167): false, with
    /// nothing asked, when there are none. Otherwise it asks, after returning, and calls
    /// `quit` with whether to go ahead: at once for Quit Anyway and Cancel, and for Wait and
    /// Quit once the last of them finishes, those queued meanwhile included.
    public func holdQuit(_ quit: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard isWriting else { return false }
        if quitWhenDone != nil {
            // Already waiting to quit: the new quit goes ahead with it.
            quitWhenDone = { quit(true) }
            return true
        }
        let askQuit = effects.askQuit
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.isWriting else { return quit(true) }
                askQuit(self.pendingWrites) { answer in
                    switch answer {
                    case .cancel: quit(false)
                    case .quitAnyway: quit(true)
                    case .waitAndQuit:
                        guard self.isWriting else { return quit(true) }
                        self.quitWhenDone = { quit(true) }
                    }
                }
            }
        }
        return true
    }

    /// Lowers the count of writes and undos not finished, and quits if that was the last and
    /// Wait and Quit is waiting.
    private func writeEnded() {
        pendingWrites -= 1
        guard pendingWrites == 0 else { return }
        batches = [:]
        saving(nil)
        quitWhenDone.map { quit in
            quitWhenDone = nil
            quit()
        }
    }

    /// The info window the art commands act on: the one whose button runs one, else the key
    /// one, else the last opened.
    var active: TagEditorWindow? {
        commandTarget ?? editors.last { $0.window.isKeyWindow } ?? editors.last
    }
    /// The info window whose button is running a command, while it runs.
    private var commandTarget: TagEditorWindow?

    public var canReplaceArt: Bool { canRun(.replaceArtwork, on: active) }
    public var canRemoveArt: Bool { canRun(.removeArtwork, on: active) }

    /// Whether `id` can run on `editor`: the one rule for the art commands, which the registry
    /// asks of the active window and each info window's buttons of their own. Any other command
    /// isn't about a window, so it's the registry's rule.
    func canRun(_ id: CommandID, on editor: TagEditorWindow?) -> Bool {
        switch id {
        case .replaceArtwork: editor?.model?.canSave == true
        case .removeArtwork: editor?.model?.canRemoveArt == true
        default: isEnabled(id)
        }
    }

    /// Get Info: opens an info window on `paths` at once and reads them into it. A window
    /// already open on the same tracks comes to the front instead. A window on one track
    /// steps through `list`, the list it was opened from, with its ‹ and › buttons.
    public func open(_ paths: [String], over window: NSWindow, list: TrackList? = nil) {
        guard !paths.isEmpty else { return }
        if let open = editors.first(where: { $0.paths == paths }) {
            present(open)
            return
        }
        let editor = TagEditorWindow(paths: paths)
        if paths.count == 1 { editor.list = list }
        editor.stepped = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.read(into: editor, over: window)
        }
        // A button runs its command on its own window, whichever is key.
        editor.run = { [weak self, weak editor] id in
            guard let self else { return }
            self.commandTarget = editor
            self.run(id)
            self.commandTarget = nil
        }
        editor.isEnabled = { [weak self, weak editor] in self?.canRun($0, on: editor) == true }
        editor.release = { [weak self] in try await self?.release($0) ?? nil }
        editor.commandsChanged = { [weak self] in self?.refreshCommands() }
        editor.saved = { [weak self, weak editor] edit in
            guard let self, let editor else { return }
            self.save(edit, from: editor, over: window)
        }
        editor.closed = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.editors.removeAll { $0 === editor }
            self.reads.removeValue(forKey: ObjectIdentifier(editor))?.stop()
            self.refreshCommands()
        }
        editors.append(editor)
        present(editor)
        refreshCommands()
        read(into: editor, over: window)
    }

    /// Enables every info window's command buttons as the rules say now, each window's art
    /// buttons by its own state.
    func refreshCommands() {
        for editor in editors { editor.refreshCommands() }
    }

    private func present(_ editor: TagEditorWindow) {
        let last = editors.last { $0 !== editor && $0.window.isVisible }
        effects.present(editor, last?.window)
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
            var (tracks, problems) = await blockingFileWork { read(paths) { stop.isStopped } }
            guard let self, let editor, self.reads[key] === stop else { return }
            self.reads[key] = nil
            for (index, count) in self.playCounts(tracks.map(\.path)).enumerated() {
                tracks[index].playCount = count
            }
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
                    "\(problems.count) of \(paths.count) files can't be read", problems, window)
                return
            }
            editor.load(TagEditorModel(tracks: tracks))
            if !problems.isEmpty {
                self.effects.alert(
                    "\(problems.count) of \(paths.count) files can't be read", problems,
                    editor.window)
            }
        }
    }

    /// Replace Artwork…: an image chosen in an open panel over the info window.
    public func chooseArt() {
        guard let editor = active, canRun(.replaceArtwork, on: editor) else { return }
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

    /// Whether `keyWindow` is an info window, whose tabs Back and Forward step through.
    public func hasTabs(_ keyWindow: NSWindow?) -> Bool {
        editors.contains { $0.window === keyWindow }
    }

    /// Back and Forward in an info window: shows the tab `step` places on in `keyWindow`,
    /// wrapping at the ends. A sheet on an info window, such as the batch question, takes the
    /// keys and nothing moves, neither the tabs behind it nor the main window. False, doing
    /// nothing, when `keyWindow` is neither.
    public func stepTab(_ step: Int, in keyWindow: NSWindow?) -> Bool {
        let window = keyWindow?.sheetParent ?? keyWindow
        guard let editor = editors.first(where: { $0.window === window }) else { return false }
        if editor.window === keyWindow { editor.stepTab(step) }
        return true
    }

    /// Undo Tag Edit: puts back the files of the newest edit, after any write still queued.
    /// `origin` is the kind of window it's pressed in; when the edit is known to come from
    /// another, it asks first (ADR 0136). It undoes the edit it looked at, or none: a write
    /// queued while it asks fails the undo instead of being undone in that edit's place.
    public func undo(over window: NSWindow, from origin: TagEditOrigin) {
        let undo = effects.undo
        let newestEdit = effects.newestEdit
        // Pending while it waits behind the writes queued before it, whose edit it has to see
        // as the newest.
        pendingWrites += 1
        writes.async {
            let newest = Result { () throws(TagWriteError) in try newestEdit() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // After the undo is queued, so a quit waiting on the queue waits for it.
                    defer { self.writeEnded() }
                    switch newest {
                    case .success(let edit):
                        let run = {
                            self.enqueue("undo the tag edit", over: window) { _ in undo(edit) }
                        }
                        guard let edit, let made = edit.origin, made != origin else { return run() }
                        self.effects.confirm(.undoing(made, edit.fileCount), window) { yes in
                            if yes { run() }
                        }
                    case .failure(let error):
                        self.effects.alert(
                            "Couldn't undo the tag edit", [error.description], window)
                    }
                }
            }
        }
    }

    /// Writes one file at once; a batch asks first, in a sheet on the info window, naming the
    /// title when it gives them all one; the window stays open with what was typed if the
    /// answer is no. The window closes once the write is queued, and a play count typed is
    /// stored then, with no question of its own: it's the index's, not the files'. Only the files whose tags can be written are written or
    /// counted; the window said which can't.
    private func save(_ edit: TagEdit, from editor: TagEditorWindow, over window: NSWindow) {
        guard let model = editor.model else { return }
        guard model.canSaveAnything else { return NSSound.beep() }
        if let note = model.collapseNote { logger.notice("\(note)") }
        let close = { [weak self, weak editor] in
            editor?.close()
            if let count = model.playCountChange { self?.setPlayCount(count, model.countedPaths) }
        }
        let paths = model.writable.map(\.path)
        guard !edit.isEmpty else { return close() }
        let write = effects.write
        let files = paths.map { (path: $0, edit: edit) }
        guard paths.count > 1 else {
            close()
            enqueue("write the tags", over: window, files: files.count) {
                write(files, .tagEditor, $0)
            }
            return
        }
        // The writable files' count, not the selection's: the window's line already says the
        // others can't be saved and Save writes only these, so the question counts what changes.
        let question =
            edit.values[.title].flatMap {
                $0.isEmpty ? nil : Confirmation.sameTitle($0, paths.count)
            }
            ?? .writing(paths.count)
        effects.confirm(question, editor.window) { [weak self] yes in
            guard yes, let self else { return }
            close()
            self.enqueue("write the tags", over: window, files: files.count) {
                write(files, .tagEditor, $0)
            }
        }
    }

    /// Writes each file its own edit as one undoable edit, after the writes queued before it,
    /// with a save's progress and its alert over `window` for what failed. The caller has
    /// asked the user: the Discogs tagger's Apply, after its confirmation (ADR 0133).
    /// `progress` hears how far it has got, on the main thread, as the status bar does, so the
    /// tagger's window can show it too, and `organizing` each step of Keep Files Organized
    /// after it that has files to move; `completion` hears the paths that weren't written,
    /// once the write has run and, when files moved, the library has them (ADR 0186).
    public func write(
        _ files: [(path: String, edit: TagEdit)], over window: NSWindow,
        progress: @escaping (TagWriteProgress) -> Void = { _ in },
        organizing: @escaping (OrganizeStep) -> Void = { _ in },
        completion: @escaping (Set<String>) -> Void = { _ in }
    ) {
        guard !files.isEmpty else { return }
        let write = effects.write
        completions[lastWrite + 1] = completion
        progresses[lastWrite + 1] = progress
        organizeSteps[lastWrite + 1] = organizing
        enqueue("write the tags", over: window, files: files.count) {
            write(files, .discogsTagger, $0)
        }
    }

    /// Runs `work` on the write queue, after the writes, undos and renames queued before it and
    /// before any queued after: the carry's reads and writes of the moves those renames record
    /// (ADR 0164).
    public func onWriteQueue(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            writes.async {
                work()
                continuation.resume()
            }
        }
    }

    /// Organize Selected Files: renames the files of `plan`, which the user confirmed, in the
    /// library folder `folder`, after the writes queued before it. A file that no longer goes
    /// where the plan said is skipped and listed (ADR 0164).
    public func organize(_ plan: FilesOrganized, in folder: String, over window: NSWindow) {
        enqueue("organize the files", over: window, organizing: (plan, folder)) { _ in
            TagWriteReport()
        }
    }

    /// Queues `work`, which is handed what to tell of its progress, and which writes `files`
    /// files, nil for an undo or an organize, which tell none. With Keep Files Organized on, or
    /// `organizing` given, the files are then renamed on the same queue, and the journal
    /// follows them before any later write or undo can look for them (ADR 0164).
    private func enqueue(
        _ action: String, over window: NSWindow, files: Int? = nil,
        organizing: (plan: FilesOrganized, folder: String)? = nil,
        _ work:
            @escaping @Sendable (@escaping @Sendable (TagWriteProgress) -> Void) ->
            TagWriteReport
    ) {
        lastWrite += 1
        let number = lastWrite
        alertWindows[number] = (action, window)
        pendingWrites += 1
        if let files {
            batches[number] = (files, nil)
            // While a save shows, its total takes in this batch at once.
            if let all = savingProgress { saving(Self.savingStatus(all)) }
        }
        let keepingIn = organizing == nil ? organizingFolder() : nil
        let layout = effects.layout
        let move = effects.move
        let follow = effects.follow
        writes.async {
            var report = work { progress in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.batches[number]?.progress = progress
                        if let all = self.savingProgress { self.saving(Self.savingStatus(all)) }
                        self.progresses[number]?(progress)
                    }
                }
            }
            var organized: FilesOrganized?
            let target =
                organizing.map { ($0.plan, $0.folder, true) }
                ?? keepingIn.flatMap { folder in
                    report.changed.isEmpty ? nil : (layout(report.changed, folder), folder, false)
                }
            if let target {
                let (plan, folder, confirmed) = target
                var result = move(plan, folder, confirmed) { progress in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.organizing(progress)
                            if progress.total > 0 { self.organizeSteps[number]?(.moving(progress)) }
                        }
                    }
                }
                // The setting is limited to the library folder: an edit of a file elsewhere
                // isn't a problem.
                if !confirmed { result.outside = [] }
                if !result.moved.isEmpty {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.organizeSteps[number]?(.updatingUndo) }
                    }
                }
                result.problems += follow(result.moved).map {
                    "\($0.path): Undo Tag Edit can't find it at its new path: \($0.detail)"
                }
                report = report.organized(result.moved, all: organizing != nil)
                organized = result
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finished(number, report, organized) }
            }
        }
    }

    /// The writes since the queue was last empty as one batch; nil until one of them reports.
    private var savingProgress: TagWriteProgress? {
        let reports = batches.values.compactMap(\.progress)
        guard !reports.isEmpty else { return nil }
        return .combined(reports, total: batches.values.map(\.files).reduce(0, +))
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

    private func finished(_ number: Int, _ report: TagWriteReport, _ organized: FilesOrganized?) {
        // Last, so a quit waiting on it goes ahead after the rescan is asked for.
        defer { writeEnded() }
        readCanUndo()
        progresses.removeValue(forKey: number)
        let step = organizeSteps.removeValue(forKey: number)
        let completion = completions.removeValue(forKey: number)
        let unwritten = Set(report.failures.map(\.path) + report.notWritten)
        let finish = { completion?(unwritten) }
        let alert = alertWindows.removeValue(forKey: number)
        // The caller hears of the end once: with files moved, when the library has them, and
        // otherwise now.
        let waitsForLibrary = organized?.moved.isEmpty == false && alert != nil
        if !waitsForLibrary { finish() }
        guard let (action, window) = alert else { return }
        if !report.changed.isEmpty || organized != nil {
            if waitsForLibrary { step?(.updatingLibrary) }
            written(report, organized) { if waitsForLibrary { finish() } }
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

/// "3 tag writes haven't finished.", asked app-modal, since a quit may come with no window.
@MainActor
private func askToQuit(
    _ count: Int, _ answer: @escaping @MainActor (TagEditing.QuitAnswer) -> Void
) {
    let alert = NSAlert()
    alert.messageText =
        count == 1
        ? "1 tag write hasn't finished."
        : "\(NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal))"
            + " tag writes haven't finished."
    alert.informativeText =
        "Wait and Quit quits once they're written. With Quit Anyway, files not yet written"
        + " keep their old tags, and one cut short is put right at the next launch."
    alert.addButton(withTitle: "Wait and Quit")
    alert.addButton(withTitle: "Quit Anyway")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn: answer(.waitAndQuit)
    case .alertSecondButtonReturn: answer(.quitAnyway)
    default: answer(.cancel)
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

extension TagWriteReport {
    /// The report with each of `moves`' files at its new path, its parse with it. With `all`,
    /// for Organize Selected Files, the moved files count as changed, for the rescan.
    fileprivate func organized(_ moves: [TrackMove], all: Bool) -> TagWriteReport {
        guard !moves.isEmpty else { return self }
        let to = Dictionary(moves.map { ($0.from, $0.to) }, uniquingKeysWith: { one, _ in one })
        var report = self
        report.changed = all ? moves.map(\.to) : changed.map { to[$0] ?? $0 }
        report.parsed = Dictionary(
            parsed.map { (to[$0.key] ?? $0.key, $0.value) }, uniquingKeysWith: { one, _ in one })
        return report
    }
}
