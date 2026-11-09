import AppKit
import Commands
import Library
import TagWriter

/// The tag editor's commands. Edit Tags… opens an info window on the selection at any time;
/// the files are written only when the user saves in it.
extension AppDelegate {
    func registerTagCommands(_ dispatcher: CommandDispatcher) {
        dispatcher.handle(
            .editTags,
            enabled: { [weak self] in self?.window != nil && self?.hasSelectedTracks() == true },
            run: { [weak self] in
                self?.withSelectedPaths { paths in
                    guard let self, let window = self.window?.window else { return }
                    self.tagEditing.open(paths, over: window)
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
    /// After Keep Files Organized or Organize Selected Files renamed files: their stats,
    /// ratings and playlist entries follow them through the move list, then the files the
    /// write changed are read at their paths now (ADR 0164).
    func carry(_ organized: FilesOrganized, then report: TagWriteReport) {
        Task { [weak self] in
            var carried: MoveListImport?
            var failure: String?
            if !organized.moved.isEmpty {
                if let watcher = self?.watcher {
                    do {
                        carried = try await watcher.importMoves(
                            lines: organized.moved.map { ($0.from, $0.to) })
                    } catch {
                        failure = "\(error)"
                    }
                } else {
                    failure = "the library isn't being watched"
                }
            }
            if !report.changed.isEmpty {
                self?.watcher?.rescan(files: report.changed, parsed: report.parsed)
            }
            // A write whose files were all in place has nothing to say.
            guard !organized.moved.isEmpty || !organized.problemLines.isEmpty else { return }
            self?.browser?.finishOrganizing(organized, carried: carried, failure: failure)
        }
    }
}
