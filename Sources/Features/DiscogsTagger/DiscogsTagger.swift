import AppKit
import Discogs
import Foundation
import Library
import Metadata
import Settings
import TagWriter

/// The Discogs tagger (phase 51): a window, opened like Year in Review, that matches library
/// albums to releases in the local catalog and writes their tags once the user has reviewed
/// them (ADR 0133). The window is made on first show, so the app pays nothing for it until then.
@MainActor
public final class DiscogsTagger {
    /// Imports the dump set in a folder into the catalog, starting over when the flag is set,
    /// as `importCatalog` does.
    public typealias Import =
        @Sendable (URL, Bool, @escaping @Sendable (CatalogImportProgress) -> Void) async throws
        -> CatalogImportSummary

    let model: TaggerModel
    private var controller: TaggerWindow?

    /// The selected library tracks' ids, for the selection scope.
    public var selectedTracks: () throws -> [Int64] {
        get { model.selectedTracks }
        set { model.selectedTracks = newValue }
    }
    /// Writes the confirmed edits as one undoable batch, over the window given.
    /// The completion hears the paths that weren't written.
    public var write:
        ([(path: String, edit: TagEdit)], NSWindow, @escaping (Set<String>) -> Void) -> Void = {
            _, _, _ in
        }
    /// Saves the mapping chosen in the Field Mapping sheet, and the user's saved ones.
    public var mappingChosen: (DiscogsMapping, [NamedDiscogsMapping]) -> Void = { _, _ in }
    /// Saves the choices the window's checkboxes set.
    public var choicesChosen: (TaggerChoices) -> Void = { _ in }
    /// Where the import's folder panel starts: the dumps folder where it is now, if set.
    public var dumpsFolder: () -> URL? = { nil }
    /// Saves the folder the user chose to import from.
    public var dumpsFolderChosen: (URL) -> Void = { _ in }

    /// `reader` gives the albums and keeps the reviews; `catalog` is the catalog's file.
    public init(
        reader: LibraryReader, catalog: URL, mapping: DiscogsMapping,
        savedMappings: [NamedDiscogsMapping], choices: TaggerChoices,
        importing: @escaping Import
    ) {
        model = TaggerModel(
            effects: .init(
                albums: { try await reader.discogsAlbums() },
                reviews: { try await reader.discogsReviews() },
                review: { try await reader.setDiscogsReview($0, files: $1) },
                match: {
                    try await matchAlbums(
                        $0, catalogAt: catalog, choosing: $1, skippingVideo: $2, progress: $3)
                },
                summaries: { try await releaseSummaries($0, catalogAt: catalog) },
                read: { ids, progress in
                    let paths = try await reader.paths(ids: ids)
                    let files = ids.compactMap { id in paths[id].map { (id: id, path: $0) } }
                    let stop = StopFlag()
                    let read = await withTaskCancellationHandler {
                        await blockingFileWork {
                            readAlbumFiles(files, isStopped: { stop.isSet }, read: progress)
                        }
                    } onCancel: {
                        stop.set()
                    }
                    try Task.checkCancellation()
                    return read
                },
                checkCatalog: { await catalogState(at: catalog) },
                unfinishedImport: { await blockingFileWork { unfinishedImport(of: catalog) } },
                importCatalog: importing),
            mapping: mapping, savedMappings: savedMappings, choices: choices)
    }

    init(model: TaggerModel) {
        self.model = model
    }

    /// The window, once shown.
    public var window: NSWindow? { controller?.window }

    /// Shows the window, checking the catalog the first time. With tracks selected in the
    /// library, it's scoped to their albums and, with a catalog in place, analyzes them at once.
    public func show() {
        let opening = controller == nil
        if let controller {
            controller.showWindow(nil)
        } else {
            let made = makeWindow()
            made.window?.center()
            made.showWindow(nil)
        }
        let scoped = model.scopeToSelection()
        guard opening || scoped else { return }
        Task {
            if opening { await model.checkCatalog() }
            if scoped, model.canAnalyze { model.analyze() }
        }
    }

    func makeWindow() -> TaggerWindow {
        let made = TaggerWindow(model: model)
        made.write = { [weak self, weak made] files, completion in
            guard let self, let window = made?.window else { return }
            write(files, window, completion)
        }
        // The model takes the mapping from `mappingChanged`, once the settings have saved it.
        made.mappingChosen = { [weak self] mapping, saved in self?.mappingChosen(mapping, saved) }
        // Saved through the settings, which hand them back to `choicesChanged`.
        made.choicesChosen = { [weak self] in self?.choicesChosen($0) }
        made.dumpsFolder = { [weak self] in self?.dumpsFolder() }
        made.dumpsFolderChosen = { [weak self] in self?.dumpsFolderChosen($0) }
        controller = made
        return made
    }

    /// The config file's choices changed, as the window's checkboxes or an edit there do.
    public func choicesChanged(_ choices: TaggerChoices) {
        model.setChoices(choices)
    }

    /// The config file's mapping changed, as an edit there or the sheet's save does.
    public func mappingChanged(_ mapping: DiscogsMapping, saved: [NamedDiscogsMapping]) {
        model.mapping = mapping
        model.savedMappings = saved
        model.changed()
    }
}

/// Whether the catalog at `url` can be opened, and what it is, as the window shows it.
private func catalogState(at url: URL) async -> TaggerModel.CatalogState {
    await blockingFileWork {
        do {
            return .ready(try CatalogStatus(at: url))
        } catch CatalogError.missing {
            return .missing
        } catch {
            return .unusable("\(error)")
        }
    }
}

/// Set when a read is stopped, so it starts no more files.
private final class StopFlag: @unchecked Sendable {
    // `stopped` is guarded by `lock`.
    private let lock = NSLock()
    private var stopped = false

    func set() { lock.withLock { stopped = true } }
    var isSet: Bool { lock.withLock { stopped } }
}
