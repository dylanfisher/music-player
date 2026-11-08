import AppKit
import Commands
import Discogs
import DiscogsTagger
import Library
import Log
import Metadata
import Settings

private let logger = moduleLogger()

/// The Discogs tagger (phase 51): opened from the File menu, as Year in Review is. It writes
/// through the tag editor's queue, so its batches show their progress, rescan what changed and
/// undo with Undo Tag Edit (ADR 0133).
extension AppDelegate {
    func registerDiscogsCommands(_ dispatcher: CommandDispatcher) {
        dispatcher.handle(
            .showDiscogsTagger, enabled: { [weak self] in self?.window != nil },
            run: { [weak self] in self?.discogsTaggerController()?.show() })
    }

    /// The tagger, made on first use; nil, after saying why, when the library can't be read.
    func discogsTaggerController() -> DiscogsTagger? {
        if let discogsTagger { return discogsTagger }
        guard let settings, let browser else { return nil }
        let reader: LibraryReader
        do {
            reader = try LibraryReader(databaseURL: libraryFileURL(in: paths.dataDirectory))
        } catch {
            fail("The Discogs tagger couldn't read the library", error)
            return nil
        }
        let catalog = paths.discogsCatalogFile(settings[\.discogsCatalogPath])
        let tagger = DiscogsTagger(
            reader: reader, catalog: catalog, mapping: settings[\.discogsMapping],
            savedMappings: settings[\.discogsSavedMappings],
            importing: { [weak self] folder, startingOver, progress in
                let configured = await MainActor.run { self?.settings?[\.watchedFolders] ?? [] }
                return try await importCatalog(
                    from: folder, to: catalog, outsideOf: try locatedFolders(configured),
                    startingOver: startingOver, progress: progress)
            })
        tagger.selectedTracks = { [weak browser] in try browser?.selectedTrackIDs() ?? [] }
        tagger.write = { [weak self] files, window in
            self?.tagEditing.write(files, over: window)
        }
        tagger.mappingChosen = { [weak self] mapping, saved in
            do {
                try settings.set(\.discogsSavedMappings, to: saved)
                try settings.set(\.discogsMapping, to: mapping)
            } catch {
                self?.fail("Couldn't save the Discogs field mapping", error)
            }
        }
        tagger.dumpsFolder = {
            guard let folder = settings[\.discogsDumpsFolder] else { return nil }
            do {
                let shares = folder.share == nil ? [] : try SystemShareMounts().mountedShares()
                return try locate(folder, among: shares)
            } catch {
                // Only where the folder panel starts: it opens where it last was instead.
                logger.notice("the Discogs dumps folder isn't where it was: \(error)")
                return nil
            }
        }
        tagger.dumpsFolderChosen = { [weak self] url in
            Task {
                let found = await blockingFileWork { Result { try folderToWatch(at: url) } }
                do {
                    let folder = try found.get()
                    try settings.set(
                        \.discogsDumpsFolder,
                        to: DumpsFolder(path: folder.path, share: folder.share))
                } catch {
                    self?.fail("Couldn't keep \(url.path) as the Discogs dumps folder", error)
                }
            }
        }
        discogsTagger = tagger
        return tagger
    }
}

/// The watched folders' paths where they are now; one on a share that isn't mounted holds
/// nothing, so no catalog can be inside it.
private func locatedFolders(_ folders: [WatchedFolder]) throws -> [String] {
    let shares =
        folders.contains { $0.share != nil } ? try SystemShareMounts().mountedShares() : []
    return folders.compactMap { folder in
        guard folder.share != nil else { return folder.path }
        if case .found(let path) = Library.locate(
            SyncFolder(path: folder.path, share: folder.share), among: shares)
        {
            return path
        }
        return nil
    }
}
