import AppKit
import Commands

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
            .undoTagEdit, enabled: { [weak self] in self?.window != nil },
            run: { [weak self] in
                guard let self, let window = self.window?.window else { return }
                self.tagEditing.undo(over: window)
            })
        dispatcher.handle(
            .replaceArtwork, enabled: { [weak self] in self?.tagEditing.canReplaceArt == true },
            run: { [weak self] in self?.tagEditing.chooseArt() })
        dispatcher.handle(
            .removeArtwork, enabled: { [weak self] in self?.tagEditing.canRemoveArt == true },
            run: { [weak self] in self?.tagEditing.removeArt() })
    }
}
