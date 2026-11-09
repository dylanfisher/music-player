import AppKit
import DisplayText
import Library
import Metadata

extension LibraryBrowser {
    /// Organize Selected Files…: works out where the selected tracks in the library folder
    /// `folder` go, asks over `window` with the number that will move, and hands the paths to
    /// `organize`, which renames them after the tag writes queued (ADR 0164).
    public func organizeSelection(
        in folder: String?, over window: NSWindow,
        organize: @escaping ([String], String) -> Void
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
        organize: @escaping ([String], String) -> Void
    ) async {
        guard let folder else {
            return report("couldn't organize the files: no library folder is set")
        }
        guard !paths.isEmpty else { return }
        // The tags are read from the volume, which may be a share that has stopped answering.
        let plan = await blockingFileWork { layoutMoves(paths, libraryFolder: folder) }
        guard !plan.moved.isEmpty else {
            return finishOrganizing(plan, carried: nil, failure: nil)
        }
        let agreed = await withCheckedContinuation { continuation in
            confirmOrganizing(plan, window) { continuation.resume(returning: $0) }
        }
        if agreed { organize(paths, folder) }
    }

    /// Says what Keep Files Organized or Organize Selected Files moved, and lists the files it
    /// didn't move, and the move list's lines that carried nothing, in the Problems window.
    public func finishOrganizing(
        _ organized: FilesOrganized, carried: MoveListImport?, failure: String?
    ) {
        var rows = organized.problemLines
        rows += carried?.problems.map { "the stats didn't follow a moved file: \($0.reason)" } ?? []
        if let failure { rows.append("the stats didn't follow the moved files: \(failure)") }
        let summary =
            organized.moved.isEmpty && rows.isEmpty ? "No files to organize" : organized.summary
        finish(summary, rows.map { Problem(terminalSafe($0)) }, as: \.organizedReport)
        if !organized.moved.isEmpty {
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
