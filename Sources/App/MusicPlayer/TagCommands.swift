import AppKit
import Commands
import Library
import TagEditor
import TagWriter

/// The tag editor's commands. Edit Tags… opens an info window on the selection at any time;
/// the files are written only when the user saves in it.
extension AppDelegate {
    func registerTagCommands(_ dispatcher: CommandDispatcher) {
        dispatcher.handle(
            .editTags,
            enabled: { [weak self] in self?.window != nil && self?.hasSelectedTracks() == true },
            run: { [weak self] in
                // The list as it is when Get Info is chosen, which its window steps through.
                let list = self?.browser?.selectedRowInList().map {
                    TrackList(count: $0.count, row: $0.row, path: $0.path)
                }
                self?.withSelectedPaths { paths in
                    guard let self, let window = self.window?.window else { return }
                    self.tagEditing.open(paths, over: window, list: list)
                }
            })
        dispatcher.handle(
            .undoTagEdit,
            enabled: { [weak self] in self?.window != nil && self?.tagEditing.canUndo == true },
            run: { [weak self] in
                guard let self, let window = self.window?.window else { return }
                // The tagger's when its window or a sheet over it is the key one, asking over
                // that, the top one; any other is the tag editor's.
                if let key = NSApp.keyWindow, self.discogsTagger?.isOwnWindow(key) == true {
                    self.tagEditing.undo(over: key, from: .discogsTagger)
                } else {
                    self.tagEditing.undo(over: window, from: .tagEditor)
                }
            })
        dispatcher.handle(.organizeFiles, enabled: hasSelectedTracks) { [weak self] in
            guard let self, let window = self.window?.window else { return }
            self.browser?.organizeSelection(
                in: self.settings?[\.libraryFolder], over: window
            ) { [weak self] plan, folder in
                self?.tagEditing.organize(plan, in: folder, over: window)
            }
        }
        dispatcher.handle(
            .replaceArtwork, enabled: { [weak self] in self?.tagEditing.canReplaceArt == true },
            run: { [weak self] in self?.tagEditing.chooseArt() })
        dispatcher.handle(
            .removeArtwork, enabled: { [weak self] in self?.tagEditing.canRemoveArt == true },
            run: { [weak self] in self?.tagEditing.removeArt() })
    }
}

extension AppDelegate {
    /// After Keep Files Organized or Organize Selected Files renamed files, or with `organized`
    /// nil at launch: the stats, ratings and playlist entries of every renamed file the index
    /// recorded follow it through the move list, then the files the write changed are read at
    /// their paths now (ADR 0164).
    func carry(_ organized: FilesOrganized?, then report: TagWriteReport?) {
        let databaseURL = libraryFileURL(in: paths.dataDirectory)
        let carrier = layoutCarrier
        Task { [weak self] in
            let serially: @Sendable (@escaping @Sendable () -> Void) async -> Void = {
                @MainActor [weak self] work in
                // Without the app there are no tag writes to wait for.
                guard let self else { return work() }
                await self.tagEditing.onWriteQueue(work)
            }
            let carry = await carrier.carry(databaseURL: databaseURL, serially: serially) {
                @MainActor [weak self] lines in
                guard let watcher = self?.watcher else {
                    throw LibraryNotWatched()
                }
                return try await watcher.importMoves(lines: lines)
            }
            if let report, !report.changed.isEmpty {
                self?.watcher?.rescan(files: report.changed, parsed: report.parsed)
            }
            // A write whose files were all in place, or a launch with nothing left to carry,
            // has nothing to say.
            guard
                organized?.moved.isEmpty == false || organized?.problemLines.isEmpty == false
                    || !carry.problems.isEmpty
            else { return }
            self?.browser?.finishOrganizing(organized, carry: carry)
        }
    }
}

private struct LibraryNotWatched: Error, CustomStringConvertible {
    var description: String { "the library isn't being watched" }
}
