import AppKit
import Commands
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
        dispatcher.handle(
            .replaceArtwork, enabled: { [weak self] in self?.tagEditing.canReplaceArt == true },
            run: { [weak self] in self?.tagEditing.chooseArt() })
        dispatcher.handle(
            .removeArtwork, enabled: { [weak self] in self?.tagEditing.canRemoveArt == true },
            run: { [weak self] in self?.tagEditing.removeArt() })
    }
}
