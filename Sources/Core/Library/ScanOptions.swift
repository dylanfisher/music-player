/// What a scan does with the files it finds changed or gone, from Settings ▸ Watched Folders
/// (ADR 0094). Files themselves are never touched either way.
public struct ScanOptions: Equatable, Sendable {
    /// Whether a walk that finished removes the tracks of files it no longer found. A folder
    /// that's missing, empty or vanished removes nothing whatever this says (ADR 0009).
    public var removesMissingTracks: Bool
    /// Whether a known file whose size or modification time changed is read again. Off, it
    /// keeps its track and its stored size and time, so it's read once this is on again.
    public var rescansModifiedFiles: Bool
    /// Folders no scan reads in, where they're found now: the staging folder, where downloads
    /// wait for review and the service deletes (ADR 0136). Not a setting of the watched folders;
    /// the watcher sets it as it finds the staging folder.
    var skippedFolders: [String]

    public init(removesMissingTracks: Bool = true, rescansModifiedFiles: Bool = true) {
        self.init(
            removesMissingTracks: removesMissingTracks, rescansModifiedFiles: rescansModifiedFiles,
            skippedFolders: [])
    }

    init(
        removesMissingTracks: Bool = true, rescansModifiedFiles: Bool = true,
        skippedFolders: [String]
    ) {
        self.removesMissingTracks = removesMissingTracks
        self.rescansModifiedFiles = rescansModifiedFiles
        self.skippedFolders = skippedFolders
    }
}
