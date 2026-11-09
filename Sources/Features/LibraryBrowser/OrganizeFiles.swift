import AppKit
import DisplayText
import Library
import Metadata

extension LibraryBrowser {
    /// Organize Selected Files…: works out where the selected tracks in the library folder
    /// `folder` go, asks over `window` with the number that will move, and hands the plan it asked
    /// about to `organize`, which renames its files after the tag writes queued (ADR 0164).
    public func organizeSelection(
        in folder: String?, over window: NSWindow,
        organize: @escaping (FilesOrganized, String) -> Void
    ) {
        Task {
            let paths: [String]
            do {
                paths = try await selectedPaths()
            } catch {
                return report("couldn't organize the files: \(error)")
            }
            await organizeFiles(paths, in: folder, over: window, organize: organize)
        }
    }

    func organizeFiles(
        _ paths: [String], in folder: String?, over window: NSWindow,
        organize: @escaping (FilesOrganized, String) -> Void
    ) async {
        guard let folder else {
            return report("couldn't organize the files: no library folder is set")
        }
        guard !paths.isEmpty else { return }
        // The tags are read from the volume, which may be a share that has stopped answering.
        let plan = await blockingFileWork { layoutMoves(paths, libraryFolder: folder) }
        guard !plan.moved.isEmpty else {
            return finishOrganizing(plan, carry: LayoutCarry())
        }
        let agreed = await withCheckedContinuation { continuation in
            confirmOrganizing(plan, window) { continuation.resume(returning: $0) }
        }
        if agreed { organize(plan, folder) }
    }

    /// Says what Keep Files Organized or Organize Selected Files moved, and lists the files it
    /// didn't move, and the moves whose stats didn't follow, in the Problems window. With
    /// `organized` nil, the carry at launch of moves recorded before.
    public func finishOrganizing(_ organized: FilesOrganized?, carry: LayoutCarry) {
        let rows = (organized?.problemLines ?? []) + carry.problems
        let summary =
            organized.map { $0.moved.isEmpty && rows.isEmpty ? "No files to organize" : $0.summary }
            ?? "The stats of \(files(carry.problems.count)) didn't follow them"
        finish(summary, rows.map { Problem(terminalSafe($0)) }, as: \.organizedReport)
        if organized?.moved.isEmpty == false || !carry.carried.isEmpty {
            refreshNow()
            edited()
        }
    }
}

/// "Organize 12 Files?" and what happens to them and to the rest of the selection.
func organizeQuestion(_ plan: FilesOrganized) -> (message: String, detail: String) {
    let moving = plan.moved.count
    let files =
        moving == 1
        ? "1 file in the library folder is" : "\(number(moving)) files in the library folder are"
    var detail =
        files + " renamed to its layout, by artist and album. Plays, ratings and playlists go with"
        + " them, and folders left empty are removed."
    var left: [String] = []
    if plan.inPlace > 0 { left.append("\(number(plan.inPlace)) already in place") }
    if !plan.outside.isEmpty {
        left.append("\(number(plan.outside.count)) not in the library folder")
    }
    if !plan.problems.isEmpty { left.append("\(number(plan.problems.count)) that can't move") }
    if !left.isEmpty {
        detail += " Left where they are: " + left.joined(separator: ", ") + "."
    }
    return (moving == 1 ? "Organize 1 File?" : "Organize \(number(moving)) Files?", detail)
}

/// Asks over `window` whether to organize what `plan` moves; answers true for Organize.
@MainActor
func askToOrganize(_ plan: FilesOrganized, over window: NSWindow, answer: @escaping (Bool) -> Void)
{
    let question = organizeQuestion(plan)
    let alert = NSAlert()
    alert.messageText = question.message
    alert.informativeText = question.detail
    alert.addButton(withTitle: "Organize")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
}
