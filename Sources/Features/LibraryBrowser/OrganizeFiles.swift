import AppKit
import DisplayText
import Library
import Metadata

extension LibraryBrowser {
    /// Organize Selected Files…: opens the question over `window` at once, counts where the
    /// selected tracks in the library folder `folder` go, asks with the number that will move,
    /// and hands the plan it asked about to `organize`, which renames its files after the tag
    /// writes queued (ADR 0164, ADR 0175).
    public func organizeSelection(
        in folder: String?, over window: NSWindow,
        organize: @escaping (FilesOrganized, String) -> Void
    ) {
        Task {
            await organizeFiles(
                { try await self.selectedPaths() }, in: folder, over: window, organize: organize)
        }
    }

    func organizeFiles(
        _ paths: @escaping @MainActor () async throws -> [String], in folder: String?,
        over window: NSWindow, organize: @escaping (FilesOrganized, String) -> Void
    ) async {
        guard let folder else {
            return report("couldn't organize the files: no library folder is set")
        }
        let sheet = OrganizeSheet()
        let stop = CountStop()
        let answer = AsyncAnswer()
        sheet.answered = { yes in
            stop.stop()
            answer.give(yes)
        }
        organizeSheet = sheet
        defer { organizeSheet = nil }
        sheet.begin(over: window)
        let selected: [String]
        do {
            selected = try await paths()
        } catch {
            sheet.end()
            return report("couldn't organize the files: \(error)")
        }
        guard !selected.isEmpty, !stop.isStopped else { return sheet.end() }
        sheet.counted(0, of: selected.count, moving: 0)
        let count = countOrganizing
        // The tags are read from the volume, which may be a share that has stopped answering.
        let plan = await blockingFileWork {
            count(
                selected, folder,
                { checked, moving in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            sheet.counted(checked, of: selected.count, moving: moving)
                        }
                    }
                }, { stop.isStopped })
        }
        guard !stop.isStopped else { return }
        guard !plan.moved.isEmpty else {
            sheet.end()
            return finishOrganizing(plan, carry: LayoutCarry())
        }
        sheet.ask(plan)
        if await answer.value { organize(plan, folder) }
    }

    /// Says what Keep Files Organized or Organize Selected Files moved, and lists the files it
    /// didn't move, and the moves whose stats didn't follow, in the Problems window. With
    /// `organized` nil, the carry at launch of moves recorded before.
    public func finishOrganizing(_ organized: FilesOrganized?, carry: LayoutCarry) {
        let rows = (organized?.problemLines ?? []) + carry.problems
        let summary =
            organized.map { organizedSummary(moved: $0.moved.count, problems: rows.count) }
            ?? "The stats of \(files(carry.problems.count)) didn't follow them"
        showOrganizing(nil)
        finish(summary, rows.map { Problem(terminalSafe($0)) }, as: \.organizedReport)
        if organized?.moved.isEmpty == false || !carry.carried.isEmpty {
            refreshNow()
            edited()
        }
    }
}

/// The counting Organize Selected Files does before it asks: where each path goes in the
/// library folder, telling the third argument how many it has checked and how many move, and
/// stopping once the fourth says so. Tests stand in for it.
typealias OrganizeCount =
    @Sendable (
        [String], String, @escaping @Sendable (Int, Int) -> Void, @escaping @Sendable () -> Bool
    ) -> FilesOrganized

/// Set by Cancel or an answer, read by the count off the main thread.
private final class CountStop: @unchecked Sendable {
    // `stopped` is guarded by `lock`.
    private let lock = NSLock()
    private var stopped = false

    func stop() { lock.withLock { stopped = true } }
    var isStopped: Bool { lock.withLock { stopped } }
}

/// The sheet's answer, awaited once.
@MainActor
private final class AsyncAnswer {
    private var answer: Bool?
    private var waiting: CheckedContinuation<Bool, Never>?

    func give(_ yes: Bool) {
        guard answer == nil else { return }
        answer = yes
        waiting?.resume(returning: yes)
        waiting = nil
    }

    var value: Bool {
        get async {
            if let answer { return answer }
            return await withCheckedContinuation { waiting = $0 }
        }
    }
}

/// "Organizing files: 12 left · Album/01 Song.flac", the file being renamed by its folder and
/// name; once every file is renamed, while the folders are tidied and the stats follow,
/// "Organizing files: finishing".
func organizingStatus(_ progress: OrganizeProgress) -> String {
    guard let current = progress.current else { return "Organizing files: finishing" }
    let parts = (current as NSString).pathComponents.suffix(2)
    return "Organizing files: \(number(progress.left)) left · "
        + terminalSafe(NSString.path(withComponents: Array(parts)))
}

/// "Organized 2,340 files; 3 problems", an organize's line in the status bar.
func organizedSummary(moved: Int, problems: Int) -> String {
    guard moved > 0 || problems > 0 else { return "No files to organize" }
    let line = "Organized \(files(moved))"
    return problems == 0 ? line : line + "; " + problemCount(problems)
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
