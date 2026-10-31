import AppKit
import Commands

/// The tag editor's commands. Edit Tags… opens the editor on the selection; the files are
/// written only when the user saves in it.
extension AppDelegate {
    func registerTagCommands(_ dispatcher: CommandDispatcher) {
        let idle = { [weak self] in
            self?.window != nil && self?.tagEditing.isBusy == false
                && self?.tagEditing.isOpen == false
        }
        dispatcher.handle(
            .editTags, enabled: { [weak self] in idle() && self?.hasSelectedTracks() == true },
            run: { [weak self] in
                self?.withSelectedPaths { paths in
                    guard let self, let window = self.window?.window else { return }
                    self.tagEditing.open(paths, over: window)
                }
            })
        dispatcher.handle(
            .undoTagEdit, enabled: idle,
            run: { [weak self] in
                guard let self, let window = self.window?.window else { return }
                self.tagEditing.undo(over: window)
            })
        dispatcher.handle(
            .replaceArtwork, enabled: { [weak self] in self?.tagEditing.isOpen == true },
            run: { [weak self] in self?.tagEditing.chooseArt() })
        dispatcher.handle(
            .removeArtwork, enabled: { [weak self] in self?.tagEditing.canRemoveArt == true },
            run: { [weak self] in self?.tagEditing.removeArt() })
    }
}
