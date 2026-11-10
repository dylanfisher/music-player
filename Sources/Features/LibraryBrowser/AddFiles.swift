import AppKit
import DisplayText
import Library
import Log
import Metadata
import Settings

private let logger = moduleLogger()

extension LibraryBrowser {
    /// Adds the audio files and folders at `urls`, dropped on the window, to the library
    /// (ADR 0124). Those in a watched folder are scanned again. With Copy Added Files on, those
    /// outside the library folder are copied into it first. Folders no watched folder holds
    /// become watched once the user agrees in a sheet; Cancel adds nothing.
    func addFiles(_ urls: [URL]) async {
        let paths = urls.map(\.standardizedFileURL.path)
        guard let roots = await watchedRoots() else { return }
        let setting = libraryFolder()
        guard !setting.copy || setting.folder != nil else {
            return report(
                "couldn't add the files: \(AppSettings().copyAddedFiles.title) is on, but no"
                    + " library folder is set")
        }
        let libraryFolder = setting.copy ? setting.folder : nil
        // The drop may be on a share that has stopped answering.
        let planned = await blockingFileWork {
            Result { () throws(AddError) in
                try planAdding(paths, watched: roots, libraryFolder: libraryFolder)
            }
        }
        let plan: AddPlan
        do {
            plan = try planned.get()
        } catch {
            return report("couldn't add the files: \(error)")
        }
        guard !plan.isEmpty else {
            return finishAdding(
                "No audio files to add", plan.problems.map { Problem(terminalSafe($0)) })
        }
        if !plan.foldersToWatch.isEmpty {
            guard let window = table.table.window else {
                return report("couldn't add the files: the library window isn't open")
            }
            let agreed = await withCheckedContinuation { continuation in
                confirmAdding(plan.foldersToWatch, window) { continuation.resume(returning: $0) }
            }
            guard agreed else { return }
        }
        var problems = plan.problems
        var copies: [String] = []
        if let libraryFolder {
            let total = plan.filesToCopy.count
            let listings = LibraryFolderListings(libraryFolder)
            for (done, source) in plan.filesToCopy.enumerated() {
                showCopying(
                    (
                        "Copying into the library folder: \(number(done + 1)) of \(number(total))",
                        Double(done) / Double(total)
                    ))
                let copied = await blockingFileWork {
                    Result { () throws(CopyError) in
                        try copyIntoLibraryFolder(source, into: listings)
                    }
                }
                switch copied {
                case .success(let copy): copies.append(copy)
                case .failure(let error):
                    logger.error("\(error)")
                    problems.append(error.description)
                }
            }
            showCopying(nil)
        }
        let rescans = plan.directoriesToRescan + plan.directoriesToRescan(afterCopyingTo: copies)
        if !rescans.isEmpty { rescanDirectories(rescans) }
        for folder in plan.foldersToWatch { watch(URL(fileURLWithPath: folder, isDirectory: true)) }
        finishAdding(
            addedSummary(plan, copied: copies.count), problems.map { Problem(terminalSafe($0)) })
    }
}

/// The audio files and folders on `pasteboard`, in order, for a drop that adds them to the
/// library. A folder is told by its URL, which Finder ends with a slash, so nothing here reads
/// the volume. Other files are left out, so a drag of only those isn't taken.
func addableFileURLs(_ pasteboard: NSPasteboard) -> [URL] {
    let urls =
        pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    return urls.filter {
        $0.hasDirectoryPath || audioFileExtensions.contains($0.pathExtension.lowercased())
    }
}

/// "Copied 3 of 4 files into the library folder · Watching 1 new folder": what a drop did.
func addedSummary(_ plan: AddPlan, copied: Int) -> String {
    var parts: [String] = []
    if !plan.filesToCopy.isEmpty {
        parts.append(
            "Copied \(number(copied)) of \(files(plan.filesToCopy.count)) into the"
                + " library folder")
    }
    if !plan.foldersToWatch.isEmpty {
        parts.append("Watching \(count(plan.foldersToWatch.count, "new folder"))")
    }
    if !plan.directoriesToRescan.isEmpty {
        parts.append("Rescanning \(count(plan.directoriesToRescan.count, "folder"))")
    }
    return parts.joined(separator: " · ")
}

/// Asks over `window` whether to watch `folders`, which no watched folder holds, so a drop's
/// files join the library; answers true for Add.
@MainActor
func askToAddFolders(_ folders: [String], over window: NSWindow, answer: @escaping (Bool) -> Void) {
    let alert = NSAlert()
    alert.messageText =
        folders.count == 1
        ? watchQuestion(folders[0])
        : "Watch \(number(folders.count)) New Folders?"
    alert.informativeText =
        (folders.count == 1 ? "This folder isn't" : "These folders aren't")
        + " watched yet. Their music joins the library, and they're added to the watched"
        + " folders:\n\n" + folders.map(terminalSafe).joined(separator: "\n")
    alert.addButton(withTitle: "Add")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
}
