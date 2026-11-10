import AppKit
import Discogs
import Foundation
import Library
import Metadata
import Recommender
import Settings
import TagWriter
import WindowPlacement

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
    /// What Get Artwork's fetch says while it runs, "Getting covers: 3 of 20"; its write then
    /// goes through the tag editor's queue.
    var coverFetch: String?

    /// What the tagger is doing, for the question at quit (ADR 0191): an Analyze, the reading
    /// before Apply, a catalog import, or Get Artwork's fetch. Empty when idle.
    public var unfinishedWork: [String] {
        [model.activityLine, coverFetch].compactMap { $0 }
    }

    /// The selected library tracks' ids, for the selection scope.
    public var selectedTracks: () throws -> [Int64] {
        get { model.selectedTracks }
        set { model.selectedTracks = newValue }
    }
    /// Writes the confirmed edits as one undoable batch, over the window given. The first
    /// closure hears how far it has got, and the second each step of Keep Files Organized
    /// after it, for the window to show; the completion hears the paths that weren't written.
    public var write:
        (
            [(path: String, edit: TagEdit)], NSWindow, @escaping (TagWriteProgress) -> Void,
            @escaping (OrganizeStep) -> Void, @escaping (Set<String>) -> Void
        ) -> Void = { _, _, _, _, _ in }
    /// Saves the mapping chosen in the Field Mapping sheet, and the user's saved ones.
    public var mappingChosen: (DiscogsMapping, [NamedDiscogsMapping]) -> Void = { _, _ in }
    /// Saves the choices the window's checkboxes set.
    public var choicesChosen: (TaggerChoices) -> Void = { _ in }
    /// Where the import's folder panel starts: the dumps folder where it is now, if set.
    public var dumpsFolder: () -> URL? = { nil }
    /// Saves the folder the user chose to import from.
    public var dumpsFolderChosen: (URL) -> Void = { _ in }
    /// Saves the source the user chose, as this Mac's.
    public var sourceChosen: (DiscogsSource) -> Void {
        get { model.sourceSaved }
        set { model.sourceSaved = newValue }
    }
    /// The layout each sheet and the album list were left at, set before the window is first
    /// shown, and what saves them as a sheet closes or the album list changes. Set later, as
    /// another tagger's change is, the sheets open at it.
    public var sheetLayouts = TaggerSheetLayouts() {
        didSet { controller?.sheetLayouts = sheetLayouts }
    }
    public var sheetLayoutsChosen: (TaggerSheetLayouts) -> Void = { _ in }
    /// Asks Get Artwork's question over the window, then calls back with Fill Missing,
    /// Replace, or nil for Cancel; tests answer it.
    var askArtwork:
        ((message: String, detail: String), NSWindow, @escaping (CoverFill?) -> Void) -> Void = {
            askForArtwork($0, over: $1, answer: $2)
        }
    /// Shows what Get Artwork couldn't do over the window; tests collect it.
    var artworkAlert: (String, [String], NSWindow) -> Void = {
        showProblems($0, $1, over: $2)
    }

    /// `reader` gives the albums and keeps the reviews; `catalog` is the catalog's file. `api`
    /// gives the Discogs API as the config file's token has it now, which the app builds, so
    /// this module reads no setting; `source` is the one this Mac last chose.
    public init(
        reader: LibraryReader, catalog: URL, mapping: DiscogsMapping,
        savedMappings: [NamedDiscogsMapping], choices: TaggerChoices,
        source: DiscogsSource?, api: @escaping @MainActor @Sendable () -> DiscogsAPI,
        importing: @escaping Import
    ) {
        model = TaggerModel(
            effects: .init(
                albums: { try await reader.discogsAlbums() },
                reviews: { try await reader.discogsReviews() },
                review: { try await reader.setDiscogsReview($0, files: $1) },
                match: { albums, chosen, skipping, source, progress in
                    try await matchAlbums(
                        albums, catalogAt: catalog, source: source,
                        api: source == .catalog ? nil : await api(), choosing: chosen,
                        skippingVideo: skipping, progress: progress)
                },
                choose: { album, previous, id, source in
                    try await chooseRelease(
                        id, for: album, after: previous, catalogAt: catalog, source: source,
                        api: source == .catalog ? nil : await api())
                },
                summaries: { try await releaseSummaries($0, catalogAt: catalog, api: await api()) },
                release: { try await releaseDetail($0, catalogAt: catalog, api: await api()) },
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
                importCatalog: importing,
                cover: { id in
                    let api = await api()
                    do throws(CoverProblem) {
                        return .success(try await api.cover(release: id))
                    } catch {
                        return .failure(error)
                    }
                },
                paths: { try await reader.paths(ids: $0) },
                pixels: { path in
                    try await blockingFileWork { Result { try artPixels(at: path) } }.get()
                },
                lookUp: { query, album in
                    try await lookUpReleases(
                        query, for: album, catalogAt: catalog, api: await api())
                }),
            mapping: mapping, savedMappings: savedMappings, choices: choices, source: source)
        model.hasToken = { api().hasToken }
    }

    init(model: TaggerModel) {
        self.model = model
    }

    /// The tagger for one staged job with a discrepancy (ADR 0146), opened from Downloads: it
    /// reads the job's files under `stagingRoot`, matches them with the job's release, or one
    /// the owner chooses (ADR 0178), in the catalog only, and writes through `StagedWriter`,
    /// whose journal is under `dataDirectory`. `resolved` hears the verdict once Apply has
    /// written, with the release written, or no verdict when only some files were written.
    package convenience init(
        stagedJob job: StagedJob, stagingRoot: String, dataDirectory: URL, catalog: URL,
        mapping: DiscogsMapping, savedMappings: [NamedDiscogsMapping], choices: TaggerChoices,
        resolved: @escaping (AutoTagRun.Verdict?, _ releaseID: Int) -> Void
    ) {
        let writer = StagedWriter(stagingRoot: stagingRoot, dataDirectory: dataDirectory)
        let sizes = StagedSizes(job, stagingRoot: stagingRoot)
        let effects = TaggerModel.StagedEffects(
            read: {
                await blockingFileWork {
                    let staged = StagedAlbum(sizes.job, stagingRoot: stagingRoot)
                    return (staged.album, staged.files, staged.problems)
                }
            },
            match: { album, release in
                let matches = try await matchAlbums(
                    [album], catalogAt: catalog, choosing: [album.id: release],
                    skippingVideo: false, progress: { _ in })
                // A release the catalog lacks isn't chosen, and the matcher picks its own.
                guard let match = matches.first, match.releaseID == release else {
                    throw ReleaseSnapshot.Problem.notInCatalog(releaseID: release)
                }
                return match
            },
            lookUp: { query, album in
                try await lookUpReleases(query, for: album, catalogAt: catalog, api: nil)
            },
            summaries: { try await releaseSummaries($0, catalogAt: catalog) },
            release: { try await releaseDetail($0, catalogAt: catalog) },
            checkCatalog: { await catalogState(at: catalog) },
            write: { edits in
                try await blockingFileWork {
                    Result {
                        let report = try writer.write(edits)
                        try sizes.wrote()
                        return report
                    }
                }.get()
            })
        self.init(
            model: TaggerModel(
                stagedJob: job, effects: effects, mapping: mapping, savedMappings: savedMappings,
                choices: choices, resolved: resolved))
    }

    /// The window, once shown.
    public var window: NSWindow? { controller?.window }

    /// Whether `window` is the tagger's window or a sheet over it, at any depth, as View
    /// Release over Other Releases is.
    public func isOwnWindow(_ window: NSWindow?) -> Bool {
        guard let own = self.window else { return false }
        var shown = window
        while let current = shown {
            if current === own { return true }
            shown = current.sheetParent
        }
        return false
    }

    /// Shows the window, checking the catalog the first time. With tracks selected in the
    /// library, it's scoped to their albums and, with a catalog in place and Local Catalog the
    /// source, analyzes them at once. The API is never asked without a click on Analyze. A
    /// staged job's tagger analyzes its one album when it first opens, so it opens on the
    /// album's tier, or says why it can't.
    public func show() {
        show(combining: false)
    }

    /// Combine Albums for Tagging: shows the window with the selection's albums joined into
    /// one and analyzes it at once from the source chosen, the API too, since the command is
    /// the click (ADR 0179). It says why when it can't.
    public func combineSelection() {
        show(combining: true)
    }

    private func show(combining: Bool) {
        let opening = controller == nil
        if let controller {
            controller.showWindow(nil)
        } else {
            let made = makeWindow()
            made.window?.keepsFrame(as: TaggerWindow.title)
            made.keepAlbumList()
            made.showWindow(nil)
        }
        let scoped = model.isStaged ? opening : model.scopeToSelection(combining: combining)
        guard opening || scoped else { return }
        Task {
            if opening { await model.checkCatalog() }
            guard scoped, model.source == .catalog || combining else { return }
            if model.canAnalyze {
                model.analyze()
            } else if model.isStaged {
                model.failed("The staged album wasn't analyzed", [model.catalogProblem])
            } else if combining {
                model.failed("The combined album wasn't analyzed", [model.catalogProblem])
            }
        }
    }

    func makeWindow() -> TaggerWindow {
        let made = TaggerWindow(model: model)
        made.write = { [weak self, weak made] files, progress, organizing, completion in
            guard let self, let window = made?.window else { return }
            write(files, window, progress, organizing, completion)
        }
        made.getArtwork = { [weak self, weak made] groups in
            guard let self, let window = made?.window else { return }
            getArtwork(groups, over: window) { [weak self] progress in
                self?.model.status = progress?.text ?? ""
                self?.model.changed()
            }
        }
        // The model takes the mapping from `mappingChanged`, once the settings have saved it.
        made.mappingChosen = { [weak self] mapping, saved in self?.mappingChosen(mapping, saved) }
        // Saved through the settings, which hand them back to `choicesChanged`.
        made.choicesChosen = { [weak self] in self?.choicesChosen($0) }
        made.dumpsFolder = { [weak self] in self?.dumpsFolder() }
        made.dumpsFolderChosen = { [weak self] in self?.dumpsFolderChosen($0) }
        made.sheetLayouts = sheetLayouts
        made.sheetLayoutsChosen = { [weak self] layouts in
            self?.sheetLayouts = layouts
            self?.sheetLayoutsChosen(layouts)
        }
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
