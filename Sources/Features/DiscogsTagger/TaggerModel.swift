import Discogs
import DisplayText
import Foundation
import Library
import Log
import Settings
import TagWriter

private let logger = moduleLogger()

/// The Discogs tagger's state and work, with no AppKit (ADRs 0131 to 0133): the catalog's
/// state and its import, Analyze over a scope, the albums by tier, a release chosen or an album
/// rejected, the changes each album's files would get, and Apply's plan. Nothing is written
/// here: Apply hands its edits to `write` once the user has confirmed.
@MainActor
final class TaggerModel {
    /// Which albums Analyze matches.
    enum Scope: CaseIterable {
        case library
        /// The albums of the tracks selected in the library window.
        case selection
        /// The albums none of whose tracks has a release id.
        case unmatched
    }

    enum CatalogState: Equatable {
        case checking
        case ready(CatalogStatus)
        /// No catalog on this Mac, as on one that never imported a dump.
        case missing
        /// One the app can't use, with why: built by another version, or unreadable.
        case unusable(String)
    }

    enum Activity: Equatable {
        case idle
        case analyzing(done: Int, total: Int)
        /// Reading the files Apply to All would write, to work out their changes.
        case reading(done: Int, total: Int)
        /// Nil until the import's first report.
        case importing(CatalogImportProgress?)

        /// The import is building its indexes, which a stop can't interrupt.
        var isIndexing: Bool {
            if case .importing(let step) = self { step?.stage == .indexing } else { false }
        }
    }

    /// An album Analyze matched, with what the user decided about it.
    struct Album {
        var album: DiscogsAlbum
        var match: AlbumMatch
        var review: DiscogsReview?
        /// The release the user chose, kept while the album is rejected so taking the
        /// rejection back remembers it again.
        var chosen: Int?
        /// The changes the user unticked in View Changes, which Apply leaves out.
        var excluded: Set<TagChange.ID> = []
        /// Whether the user unticked the cover in View Changes.
        var coverExcluded = false
        /// Handed to the writer in this session.
        var applied = false
        /// The files the user left out, by id: they aren't matched, read or written.
        var leftOut: Set<Int64> = []

        var id: Int64 { album.id }
        /// The album as it's matched and written: its files but those left out.
        var matched: DiscogsAlbum { Self.kept(album, leaving: leftOut) }
        var isRejected: Bool { review == .rejected }

        /// `album` without the files in `leftOut`.
        static func kept(_ album: DiscogsAlbum, leaving leftOut: Set<Int64>) -> DiscogsAlbum {
            var kept = album
            kept.tracks.removeAll { leftOut.contains($0.fileID) }
            return kept
        }

        /// The files of `leftOut` that `album` can leave out: none when they're all its files,
        /// as a rescan can make them.
        static func leftOut(_ leftOut: Set<Int64>, of album: DiscogsAlbum) -> Set<Int64> {
            kept(album, leaving: leftOut).tracks.isEmpty ? [] : leftOut
        }
    }

    /// What Apply writes, for its confirmation sheet.
    struct ApplyPlan {
        var albumIDs: [Int64]
        var files: [(path: String, edit: TagEdit)]
        /// The album each file belongs to, by path.
        var albumOfPath: [String: Int64] = [:]
        var fieldCount: Int
        /// The files that get the release's cover.
        var coverCount = 0
        /// The albums left out, each with why: a file that couldn't be read, or a value no
        /// format holds.
        var problems: [String]
    }

    /// What the model does to the index, the catalog and the files, so tests can stand in
    /// for each.
    struct Effects: Sendable {
        var albums: @Sendable () async throws -> [DiscogsAlbum]
        var reviews: @Sendable () async throws -> [Int64: DiscogsReview]
        var review: @Sendable (DiscogsReview?, [Int64]) async throws -> Void
        /// Matches the albums from the source given, taking the chosen releases and leaving
        /// out video releases when the flag is set.
        var match:
            @Sendable (
                [DiscogsAlbum], [Int64: Int], Bool, DiscogsSource,
                @escaping @Sendable (AlbumMatchProgress) -> Void
            ) async throws -> [AlbumMatch]
        /// Matches the album with the release the user chose, after its match until now, from
        /// the source given: that release alone, with no search (ADR 0170).
        var choose:
            @Sendable (DiscogsAlbum, AlbumMatch, Int, DiscogsSource) async throws -> AlbumMatch
        var summaries: @Sendable ([Int]) async throws -> [ReleaseSummary]
        /// A release as View Release shows it; nil when the catalog lacks it.
        var release: @Sendable (Int) async throws -> ReleaseDetail?
        /// Reads the files by id, telling its last argument how many are done.
        var read:
            @Sendable ([Int64], @escaping @Sendable (Int) -> Void) async throws -> (
                files: [AlbumFile], problems: [String]
            )
        var checkCatalog: @Sendable () async -> CatalogState
        /// The import that stopped before it finished, if any (ADR 0134).
        var unfinishedImport: @Sendable () async -> UnfinishedImport?
        /// Imports the dump set in the folder, starting over when the flag is set.
        var importCatalog:
            @Sendable (URL, Bool, @escaping @Sendable (CatalogImportProgress) -> Void) async throws
                -> CatalogImportSummary
        /// The release's primary image from Discogs, checked (ADR 0140).
        var cover: @Sendable (Int) async -> Result<Cover, CoverProblem> = { _ in
            .failure(.needsToken)
        }
        /// The library's paths of the files by id, for Get Artwork.
        var paths: @Sendable ([Int64]) async throws -> [Int64: String] = { _ in [:] }
        /// The pixels of the art the file at a path shows, nil for none, read off the main
        /// thread, for Get Artwork's Fill Missing.
        var pixels: @Sendable (String) async throws -> Int? = { _ in nil }
        /// Look Up Release's search for the album given, the catalog first, then Discogs.
        var lookUp: @Sendable (ReleaseQuery, DiscogsAlbum) async throws -> ReleaseLookup = {
            _, _ in throw LookUpUnavailable()
        }
    }

    /// A tagger without Look Up Release, as a staged job's is.
    struct LookUpUnavailable: Error, CustomStringConvertible {
        var description: String { "this tagger can't look releases up" }
    }

    let effects: Effects
    /// The staged job the tagger is open on; nil for the library's tagger.
    let staged: Staged?
    private(set) var catalog = CatalogState.checking
    /// An import stopped, quit or killed before it finished, which Resume Import carries on.
    private(set) var unfinished: UnfinishedImport?
    private(set) var activity = Activity.idle
    /// What the last Analyze, import or Apply ended with, for the line under the toolbar.
    var status = ""
    /// Where Analyze looks releases up. Until the first catalog check, the saved one, or the
    /// catalog; then, when none was saved, the catalog when there is one, else the API.
    private(set) var source: DiscogsSource
    /// Whether a source was saved or chosen, which the first catalog check then leaves alone.
    private var sourceChosen: Bool
    /// The running Analyze's last progress: the API's albums and its waits.
    private(set) var matchProgress: AlbumMatchProgress?
    /// Whether the config file has a Discogs token, without which the API only looks up the
    /// release ids albums are tagged with.
    var hasToken: () -> Bool = { false }
    /// Saves the source the user chose, as this Mac's.
    var sourceSaved: (DiscogsSource) -> Void = { _ in }
    var scope = Scope.library
    private(set) var albums: [Album] = [] {
        didSet { tierOrder = [:] }
    }
    /// Each tab's albums as places in `albums`, in list order, once sorted: the window lists
    /// them on every progress report, and sorting thousands each time stalls it.
    private var tierOrder: [TaggerTab: [Int]] = [:]
    /// The files left out of each album, by album id, kept for the session so a new Analyze
    /// leaves them out too (ADR 0157).
    private var leftOutFiles: [Int64: Set<Int64>] = [:]
    /// The album being matched again, for a release chosen or a file left out or put back;
    /// one at a time.
    private(set) var rematchingID: Int64?
    var tab = TaggerTab.exact
    var selectedID: Int64?
    var mapping: DiscogsMapping {
        didSet { forgetChangeCounts() }
    }
    var savedMappings: [NamedDiscogsMapping]
    private(set) var choices: TaggerChoices {
        didSet { forgetChangeCounts() }
    }
    /// How many changes View Changes would show for each album, by id, once its files are
    /// read: the tags Apply writes, the cover aside. An album's is forgotten when its match,
    /// its files left out or its unticked changes change, or a write of it fails; all of them
    /// when Analyze runs or the mapping or the choices change.
    private(set) var changeCounts: [Int64: Int] = [:]
    /// The albums whose count couldn't be known, as when a file can't be read, which aren't
    /// read again until their counts are forgotten.
    private var uncounted: Set<Int64> = []
    /// How long an album stays selected before its files are read for its count, so moving
    /// through the list reads only the album stopped on.
    var countDelayNanoseconds: UInt64 = 300_000_000
    /// The count being read: its album, and `countClock` when it started.
    private var counting: (task: Task<Void, Never>, albumID: Int64, started: Int)?
    /// Goes up each time a count is forgotten, so a read started before is dropped.
    private var countClock = 0
    /// When each album's count was last forgotten by `countClock`, and when all of them were.
    private var forgottenAt: [Int64: Int] = [:]
    private var allForgottenAt = 0

    /// Called after anything shown changes.
    var changed: () -> Void = {}
    /// Called with a failure's message and details, for an alert.
    var failed: (String, [String]) -> Void = { _, _ in }
    /// The selected library tracks' ids, for the selection scope.
    var selectedTracks: () throws -> [Int64] = { [] }
    /// Writes the files' edits as one undoable batch; called only after the user confirmed.
    /// The completion hears the paths that weren't written.
    /// It tells its second argument how far it has got, and its last the paths not written.
    var write: Write = { _, _, _ in }
    typealias Write =
        (
            [(path: String, edit: TagEdit)], @escaping (TagWriteProgress) -> Void,
            @escaping (Set<String>) -> Void
        ) -> Void
    /// The writes handed over and not yet finished, by number, which the window shows the
    /// progress of.
    private(set) var writing: [Int: Writing] = [:]
    private var writes = 0

    /// A write handed over and not yet finished: how many tags and files it writes, and how
    /// far it has got; nil before its first report, and for a staged write, which has none.
    struct Writing: Equatable {
        var tags: Int
        var files: Int
        var progress: TagWriteProgress?
    }

    private var work: Task<Void, Never>?
    /// Apply's read of the files, which Stop cancels too.
    private var reading: Task<(files: [AlbumFile], problems: [String]), any Error>?
    /// Counts the runs started, so a late progress report of an older one is dropped.
    private var run = 0
    /// Each release's cover as fetched this session, so Apply after View Changes, or a second
    /// Apply, asks Discogs once.
    private var covers: [Int: Result<Cover, CoverProblem>] = [:]

    init(
        effects: Effects, mapping: DiscogsMapping, savedMappings: [NamedDiscogsMapping],
        choices: TaggerChoices, source: DiscogsSource? = nil, staged: Staged? = nil
    ) {
        self.effects = effects
        self.staged = staged
        // A staged job's release is looked up in the local catalog only (ADR 0146).
        self.source = staged == nil ? source ?? .catalog : .catalog
        sourceChosen = source != nil || staged != nil
        self.mapping = mapping
        self.savedMappings = savedMappings
        self.choices = choices
    }

    /// Takes the window's choices. A change to the skip rescores the albums shown, with an
    /// Analyze of the scope; the others apply to the changes worked out next.
    func setChoices(_ new: TaggerChoices) {
        guard new != choices else { return }
        let analyzing = if case .analyzing = activity { true } else { false }
        let rescore = new.skipVideo != choices.skipVideo && (!albums.isEmpty || analyzing)
        choices = new
        changed()
        // The menu can change the skip while work runs, which matched with the old one.
        guard rescore else { return }
        if isBusy {
            rescoreWhenIdle = true
        } else {
            analyze()
        }
    }

    /// Whether the skip changed while work ran, so the albums are matched again once it ends.
    private var rescoreWhenIdle = false

    /// The changes `album`'s files would get from the mapping, with the choices applied.
    func changeSet(_ files: [AlbumFile], _ album: Album) -> AlbumChangeSet {
        Discogs.changeSet(
            for: files, match: album.match,
            mapping: choices.keepExistingValues ? mapping.keepingExistingValues() : mapping,
            fillingSortArtist: choices.fillSortArtist)
    }

    var isBusy: Bool { activity != .idle }
    /// Whether Analyze can start: the catalog source needs a catalog in place, Both a finished
    /// check, and the API nothing more (ADR 0139).
    var canAnalyze: Bool {
        guard !isBusy else { return false }
        return switch source {
        case .catalog: isCatalogReady
        case .api: true
        case .both: catalog != .checking
        }
    }

    var isCatalogReady: Bool {
        if case .ready = catalog { true } else { false }
    }

    /// The source a run asks: Both without a catalog, as on a Mac that has none, asks the API
    /// alone.
    var runSource: DiscogsSource { source == .both && !isCatalogReady ? .api : source }

    /// Makes `source` the one Analyze asks, and saves it. A staged job keeps the catalog.
    func chooseSource(_ source: DiscogsSource) {
        guard staged == nil, source != self.source || !sourceChosen else { return }
        self.source = source
        sourceChosen = true
        sourceSaved(source)
        changed()
    }

    /// The albums `tab` lists, by artist and then title.
    func albums(in tab: TaggerTab) -> [Album] {
        if let order = tierOrder[tab] { return order.map { albums[$0] } }
        let order = albums.indices.filter { tab.lists(albums[$0].match) }.sorted { a, b in
            let (a, b) = (albums[a].album, albums[b].album)
            let artist = (a.artist ?? "").localizedStandardCompare(b.artist ?? "")
            return artist != .orderedSame
                ? artist == .orderedAscending
                : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        tierOrder[tab] = order
        return order.map { albums[$0] }
    }

    func count(_ tab: TaggerTab) -> Int { albums.count { tab.lists($0.match) } }

    var selected: Album? { albums.first { $0.id == selectedID } }

    /// Whether the selected album's rows can be dragged to another track: its match is a guess.
    var canRemap: Bool {
        guard let tier = selected?.match.tier else { return false }
        return tier == .likely || tier == .incomplete
    }

    /// The tabs Apply to All writes: those a match set can be trusted in after a review.
    static let appliedTabs: [TaggerTab] = [.exact, .likely, .safe, .titlesFit, .matched]

    // MARK: - The catalog

    /// Checks the catalog's file and any unfinished import, as the window opens and after an
    /// import.
    func checkCatalog() async {
        catalog = .checking
        changed()
        catalog = await effects.checkCatalog()
        unfinished = await effects.unfinishedImport()
        if !sourceChosen { source = isCatalogReady ? .catalog : .api }
        changed()
    }

    /// Imports the newest dump set in `folder`, replacing the catalog once it's complete. An
    /// unfinished import of the set is carried on unless `startingOver`. Stop cancels it at its
    /// next checkpoint, for Resume Import, and leaves the old catalog.
    func importDump(from folder: URL, startingOver: Bool = false) {
        guard !isBusy else { return }
        run += 1
        let current = run
        activity = .importing(nil)
        status = ""
        changed()
        let importing = effects.importCatalog
        work = Task {
            do {
                let summary = try await importing(folder, startingOver) { progress in
                    Task { @MainActor [self] in
                        guard self.run == current, case .importing = activity else { return }
                        activity = .importing(progress)
                        changed()
                    }
                }
                status = String(
                    format: "Imported the %@ dump: %@ releases, a %.1f GB catalog",
                    summary.dumpDate, number(summary.records[.releases] ?? 0),
                    Double(summary.catalogBytes) / 1e9)
            } catch CatalogImportError.stopped {
                status = "Import stopped; Resume Import carries on from here"
            } catch {
                status = "Import failed; the catalog is as it was"
                failed("The Discogs dump couldn't be imported", ["\(error)"])
            }
            finish(current)
            await checkCatalog()
        }
    }

    // MARK: - Analyze

    /// Scopes the window to the library's selection, when there is one and nothing runs, whose
    /// albums are the scope's; returns whether it did.
    func scopeToSelection() -> Bool {
        guard !isBusy else { return false }
        do {
            guard try !selectedTracks().isEmpty else { return false }
        } catch {
            failed("The selected tracks couldn't be read", ["\(error)"])
            return false
        }
        scope = .selection
        changed()
        return true
    }

    /// Matches the scope's albums from the source, off the main thread, taking each album's
    /// remembered review; the albums shown are replaced once it finishes. A Discogs error that
    /// stops the run is one alert, and the albums shown stay the last run's.
    func analyze() {
        guard canAnalyze else { return }
        let selection: Set<Int64>
        do {
            selection = scope == .selection ? Set(try selectedTracks()) : []
        } catch {
            return failed("The selected tracks couldn't be read", ["\(error)"])
        }
        if scope == .selection, selection.isEmpty {
            return failed("No tracks are selected", ["Select albums in the library window first."])
        }
        run += 1
        let current = run
        activity = .analyzing(done: 0, total: 0)
        matchProgress = nil
        status = ""
        changed()
        let scope = scope
        let source = runSource
        let alone = source != self.source
        let effects = effects
        let skipsVideo = choices.skipVideo
        let started = Date()
        work = Task {
            do {
                let all = try await effects.albums()
                let albums = all.filter { album in
                    switch scope {
                    case .library: true
                    case .selection: album.tracks.contains { selection.contains($0.fileID) }
                    case .unmatched: album.tracks.allSatisfy { $0.releaseID == nil }
                    }
                }
                let reviews = try await effects.reviews()
                let chosen = reviews.compactMapValues { review -> Int? in
                    if case .chosen(let id) = review { id } else { nil }
                }
                let leftOut = albums.map { Album.leftOut(leftOutFiles[$0.id] ?? [], of: $0) }
                let matched = zip(albums, leftOut).map { Album.kept($0, leaving: $1) }
                let matches: [AlbumMatch]
                // Both keeps the catalog's matches when the API stops (ADR 0139).
                var apiStopped: DiscogsAPIError?
                do {
                    matches = try await effects.match(matched, chosen, skipsVideo, source) {
                        progress in
                        Task { @MainActor [self] in
                            guard self.run == current, case .analyzing = activity else { return }
                            activity = .analyzing(
                                done: progress.albumsDone, total: progress.albumCount)
                            matchProgress = progress
                            changed()
                        }
                    }
                } catch let stopped as APIStoppedMatching {
                    matches = stopped.matches
                    apiStopped = stopped.error
                }
                self.albums = zip(albums.indices, matches).map { index, match in
                    let album = albums[index]
                    return Album(
                        album: album, match: match, review: reviews[album.id],
                        chosen: chosen[album.id], leftOut: leftOut[index])
                }
                forgetChangeCounts()
                // A staged job's one album opens on its tier's tab, whichever it is.
                if staged != nil, let only = self.albums.first { tab = TaggerTab(only.match.tier) }
                if selected == nil { selectedID = self.albums(in: tab).first?.id }
                status = String(
                    format: "Analyzed %@ albums in %.1f s", number(albums.count),
                    Date().timeIntervalSince(started))
                if alone { status += "; with no catalog, Both asked the Discogs API alone" }
                if let apiStopped {
                    status += "; Discogs stopped, so some albums have only the catalog's match"
                    failed(
                        sentence(apiStopped.description),
                        [
                            "The albums are shown as the catalog matched them, and as the Discogs"
                                + " API did until it stopped."
                        ])
                }

            } catch is CancellationError {
                status = "Analyze stopped; the albums shown are the last run's"
            } catch let error as DiscogsAPIError {
                status = "Analyze stopped; the albums shown are the last run's"
                failed(sentence(error.description), [])
            } catch {
                status = "Analyze failed"
                failed("The albums couldn't be matched", ["\(error)"])
            }
            finish(current)
        }
    }

    /// Stops the Analyze, read or import running.
    func stop() {
        work?.cancel()
        reading?.cancel()
    }

    /// Returns once the work running has finished or stopped.
    func finished() async {
        await work?.value
        _ = try? await reading?.value
    }

    private func finish(_ current: Int) {
        guard run == current else { return }
        activity = .idle
        work = nil
        changed()
        if rescoreWhenIdle {
            rescoreWhenIdle = false
            analyze()
        }
    }

    // MARK: - Reviewing an album

    /// Whether Look Up Release can search for the selected album: not in a staged job, whose
    /// release is fixed, nor while work runs.
    var canLookUp: Bool { selected != nil && staged == nil && !isBusy && rematchingID == nil }

    /// What Look Up Release's fields start with: the album's artist and title as tagged.
    func lookUpQuery() -> ReleaseQuery {
        ReleaseQuery(artist: selected?.album.artist ?? "", title: selected?.album.title ?? "")
    }

    /// Searches for `query`, the catalog first, then Discogs, each release scored against the
    /// selected album's files but those left out.
    func lookUp(_ query: ReleaseQuery) async throws -> ReleaseLookup {
        guard let album = selected?.matched else { throw LookUpUnavailable() }
        return try await effects.lookUp(query, album)
    }

    /// Makes `releaseID` the album's match, scored against its files, and remembers it. Only
    /// that release is loaded, so no search runs again (ADR 0170). A release from the API, as
    /// Look Up Release can find, is loaded from the API even when the source is the catalog.
    func choose(_ releaseID: Int, for albumID: Int64, from origin: MatchOrigin = .catalog) async {
        guard let album = albums.first(where: { $0.id == albumID }) else { return }
        let review = DiscogsReview.chosen(releaseID: releaseID)
        let effects = effects
        let source = source(for: origin)
        await rematch(
            albumID, leaving: album.leftOut, failure: "The release couldn't be chosen",
            matching: { kept, previous in
                try await effects.choose(kept, previous, releaseID, source)
            },
            save: { try await effects.review(review, album.album.tracks.map(\.fileID)) },
            update: { chosen in
                chosen.review = review
                chosen.chosen = releaseID
            })
    }

    /// Matches the album again without the files in `leftOut`, through `matching`, which
    /// hears the album without them and its match until now: one album at a time, and not
    /// while other work runs. `save` runs once the match is made, before the album takes it,
    /// and `update` changes what else goes with it. A failure is an alert of `failure`.
    private func rematch(
        _ albumID: Int64, leaving leftOut: Set<Int64>, failure: String,
        matching: (DiscogsAlbum, AlbumMatch) async throws -> AlbumMatch,
        save: () async throws -> Void = {}, update: (inout Album) -> Void = { _ in }
    ) async {
        guard rematchingID == nil, !isBusy,
            let album = albums.first(where: { $0.id == albumID })
        else { return }
        let kept = Album.kept(album.album, leaving: leftOut)
        guard !kept.tracks.isEmpty else { return }
        rematchingID = albumID
        changed()
        defer {
            rematchingID = nil
            changed()
        }
        do {
            let match = try await matching(kept, album.match)
            try await save()
            guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
            leftOutFiles[albumID] = leftOut.isEmpty ? nil : leftOut
            albums[index].leftOut = leftOut
            albums[index].match = match
            albums[index].excluded = []
            update(&albums[index])
            forgetChangeCounts(of: albumID)
            if selectedID == albumID { tab = TaggerTab(match.tier) }
        } catch {
            self.failed(failure, ["\(error)"])
        }
    }

    /// The source that matches an album again with a release from `origin`: a release from the
    /// API, as Look Up can find, needs the API even when the source is the catalog.
    private func source(for origin: MatchOrigin) -> DiscogsSource {
        origin == .api && runSource == .catalog ? (isCatalogReady ? .both : .api) : runSource
    }

    /// Whether a file of the selected album can be left out or put back: not in a staged job,
    /// whose files are all moved into the library together (ADR 0157), nor while work runs.
    var canLeaveOut: Bool {
        guard let album = selected else { return false }
        return staged == nil && !isBusy && rematchingID == nil && !album.applied
    }

    /// Leaves the file `fileID` out of its album, or puts it back, then matches the album
    /// again without the files left out, with the release the user chose if any. The last
    /// file can't be left out.
    func setLeftOut(_ out: Bool, _ fileID: Int64, of albumID: Int64) async {
        guard canLeaveOut, let album = albums.first(where: { $0.id == albumID }),
            album.album.tracks.contains(where: { $0.fileID == fileID }),
            album.leftOut.contains(fileID) != out
        else { return }
        var leftOut = album.leftOut
        if out { leftOut.insert(fileID) } else { leftOut.remove(fileID) }
        let effects = effects
        let chosen = album.chosen.map { [albumID: $0] } ?? [:]
        let skipsVideo = choices.skipVideo
        let source = source(for: album.match.origin)
        await rematch(
            albumID, leaving: leftOut, failure: "The album couldn't be matched again",
            matching: { kept, _ in
                try await effects.match([kept], chosen, skipsVideo, source) { _ in }[0]
            })
    }

    /// Rejects the album, so Apply to All leaves it out, or takes the rejection back; both are
    /// remembered.
    func setRejected(_ rejected: Bool, _ albumID: Int64) async {
        guard let album = albums.first(where: { $0.id == albumID }) else { return }
        let review: DiscogsReview? =
            rejected ? .rejected : album.chosen.map { DiscogsReview.chosen(releaseID: $0) }
        do {
            try await effects.review(review, album.album.tracks.map(\.fileID))
            guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
            albums[index].review = review
            changed()
        } catch {
            failed("The review couldn't be saved", ["\(error)"])
        }
    }

    /// Maps the file `fileID` of the selected album to the track at `track`, as a dragged row.
    func assign(_ fileID: Int64, to track: Int?) {
        guard canRemap, let index = albums.firstIndex(where: { $0.id == selectedID }) else {
            return
        }
        albums[index].match.assign(fileID, to: track)
        albums[index].excluded = []
        forgetChangeCounts(of: albums[index].id)
        changed()
    }

    /// The other releases the selected album might be, best first, with the chosen one first
    /// of all; each with its tracklist score where the matcher scored it.
    func candidates() async throws -> [(summary: ReleaseSummary, score: Double?)] {
        guard let album = selected else { return [] }
        var ids = album.match.candidates.map(\.releaseID)
        if let chosen = album.match.releaseID { ids.insert(chosen, at: 0) }
        let scores = Dictionary(
            album.match.candidates.map { ($0.releaseID, $0.tracklistScore) },
            uniquingKeysWith: { first, _ in first })
        return try await effects.summaries(ids).map { ($0, scores[$0.id]) }
    }

    /// Release `id` as View Release shows it; nil when the catalog lacks it.
    func release(_ id: Int) async throws -> ReleaseDetail? {
        try await effects.release(id)
    }

    /// What the mapping would change in the album's files, read now; nil for an album not
    /// shown.
    func changeSet(for albumID: Int64) async throws -> (AlbumChangeSet, problems: [String])? {
        guard let album = albums.first(where: { $0.id == albumID }) else { return nil }
        let started = countClock
        let (files, read) = try await effects.read(album.matched.tracks.map(\.fileID)) { _ in }
        var problems = read
        // A file moved or removed since the scan is in neither list; Apply refuses such an album.
        let missing = album.matched.tracks.count - files.count - read.count
        if missing > 0 {
            problems.append("\(missing) file\(missing == 1 ? "" : "s") no longer in the library")
        }
        let changes = changeSet(files, album)
        // The album, the mapping or the choices can have changed during the read.
        if problems.isEmpty, isCountCurrent(albumID, since: started) {
            changeCounts[albumID] = keptChanges(changes, album)
        }
        let (set, problem) = await covered(changes, album)
        return (set, problems + (problem.map { [$0] } ?? []))
    }

    /// `set` with the release's cover, when the artwork mode and a token ask for one, and why
    /// the album has none when it can't have it. Each release's cover is fetched once.
    private func covered(_ set: AlbumChangeSet, _ album: Album) async -> (
        AlbumChangeSet, problem: String?
    ) {
        guard choices.artwork != .off, let releaseID = album.match.releaseID else {
            return (set, nil)
        }
        guard hasToken() else {
            return (set, CoverProblem.needsToken.line(for: albumTitle(album.album)))
        }
        let result: Result<Cover, CoverProblem>
        if let known = covers[releaseID] {
            result = known
        } else {
            result = await effects.cover(releaseID)
            // A failure the network, the rate limit or a stop caused is asked again next time.
            switch result {
            case .failure(let problem) where !problem.isLasting: break
            default: covers[releaseID] = result
            }
        }
        switch result {
        case .success(let cover): return (set.covering(cover, mode: choices.artwork), nil)
        case .failure(let problem): return (set, problem.line(for: albumTitle(album.album)))
        }
    }

    /// Keeps the changes the user unticked in View Changes out of Apply, and the cover when
    /// `coverExcluded`.
    func setExcluded(
        _ excluded: Set<TagChange.ID>, coverExcluded: Bool = false, for albumID: Int64
    ) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        albums[index].excluded = excluded
        albums[index].coverExcluded = coverExcluded
        forgetChangeCounts(of: albumID)
        changed()
    }

    // MARK: - Counting the changes

    /// Forgets the count of the album `albumID`, or of every album when nil, and drops a read
    /// of it running.
    private func forgetChangeCounts(of albumID: Int64? = nil) {
        countClock += 1
        if let albumID {
            forgottenAt[albumID] = countClock
            changeCounts[albumID] = nil
            uncounted.remove(albumID)
        } else {
            allForgottenAt = countClock
            forgottenAt = [:]
            changeCounts = [:]
            uncounted = []
        }
        if let counting, albumID == nil || counting.albumID == albumID {
            counting.task.cancel()
            self.counting = nil
        }
    }

    /// Whether the album's count hasn't been forgotten since `countClock` was `started`.
    private func isCountCurrent(_ albumID: Int64, since started: Int) -> Bool {
        max(forgottenAt[albumID] ?? 0, allForgottenAt) <= started
    }

    /// Reads the selected album's files, after `countDelayNanoseconds`, for its count of
    /// changes, unless it's known, can't be known, is being read, written already, rejected
    /// or without a release, or other work runs.
    func countChanges() {
        guard !isBusy, let album = selected, album.match.release != nil, !album.isRejected,
            !album.applied, changeCounts[album.id] == nil, !uncounted.contains(album.id)
        else { return }
        if let counting, counting.albumID == album.id,
            isCountCurrent(album.id, since: counting.started)
        {
            return
        }
        counting?.task.cancel()
        let started = countClock
        let delay = countDelayNanoseconds
        let read = effects.read
        let albumID = album.id
        let ids = album.matched.tracks.map(\.fileID)
        let task = Task {
            do {
                try await Task.sleep(nanoseconds: delay)
                let (files, problems) = try await read(ids) { _ in }
                guard isCountCurrent(albumID, since: started), !Task.isCancelled else { return }
                counting = nil
                // A file that can't be read leaves the count unknown, until the album changes:
                // View Changes says why.
                guard problems.isEmpty, files.count == ids.count,
                    let album = albums.first(where: { $0.id == albumID })
                else {
                    uncounted.insert(albumID)
                    return
                }
                changeCounts[albumID] = keptChanges(changeSet(files, album), album)
                changed()
            } catch is CancellationError {
                // A newer selection or change took its place.
            } catch {
                // Only the button's count is lost; View Changes reads the files again and
                // shows the error.
                logger.notice("the changes of album \(albumID) weren't counted: \(error)")
                if isCountCurrent(albumID, since: started) { uncounted.insert(albumID) }
            }
        }
        counting = (task, albumID, started)
    }

    /// The changes in `set` that View Changes leaves ticked.
    private func keptChanges(_ set: AlbumChangeSet, _ album: Album) -> Int {
        set.files.flatMap(\.changes).count { !album.excluded.contains($0.id) }
    }

    // MARK: - Apply

    /// The albums Apply to All in `tab` writes: those not rejected and not written already.
    func applicable(_ tab: TaggerTab) -> [Album] {
        albums(in: tab).filter { !$0.isRejected && !$0.applied && $0.match.release != nil }
    }

    /// Reads the files of `albumIDs` and works out what Apply writes to them, with progress;
    /// nil when stopped.
    func plan(_ albumIDs: [Int64]) async -> ApplyPlan? {
        guard !isBusy else { return nil }
        let wanted = Set(albumIDs)
        let chosen = albums.filter { wanted.contains($0.id) }
        let fileIDs = chosen.flatMap { $0.matched.tracks.map(\.fileID) }
        run += 1
        let current = run
        activity = .reading(done: 0, total: fileIDs.count)
        changed()
        let read = effects.read
        let task = Task {
            try await read(fileIDs) { done in
                Task { @MainActor [self] in
                    guard self.run == current, case .reading = activity else { return }
                    activity = .reading(done: done, total: fileIDs.count)
                    changed()
                }
            }
        }
        reading = task
        let files: [AlbumFile]
        let readProblems: [String]
        do {
            (files, readProblems) = try await task.value
        } catch is CancellationError {
            reading = nil
            status = "Stopped reading the files; nothing was written"
            finish(current)
            return nil
        } catch {
            reading = nil
            status = "Couldn't read the files; nothing was written"
            finish(current)
            failed("The albums' files couldn't be read", ["\(error)"])
            return nil
        }
        reading = nil
        finish(current)
        let byID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        var plan = ApplyPlan(albumIDs: [], files: [], fieldCount: 0, problems: readProblems)
        for album in chosen {
            let albumFiles = album.matched.tracks.compactMap { byID[$0.fileID] }
            let unread = album.matched.tracks.count - albumFiles.count
            guard unread == 0 else {
                // Each file that couldn't be read is a problem of its own already.
                plan.problems.append(
                    "\(albumTitle(album.album)): \(unread) file\(unread == 1 ? "" : "s")"
                        + " unreadable or no longer in the library")
                continue
            }
            let (set, coverProblem) = await covered(changeSet(albumFiles, album), album)
            if let coverProblem { plan.problems.append(coverProblem) }
            do {
                let edits = try set.edits(
                    including: { !album.excluded.contains($0) },
                    includingCover: !album.coverExcluded)
                guard !edits.isEmpty else { continue }
                plan.albumIDs.append(album.id)
                plan.files += edits
                for (path, _) in edits { plan.albumOfPath[path] = album.id }
                plan.fieldCount += set.files.flatMap(\.changes).count {
                    !album.excluded.contains($0.id)
                }
                if !album.coverExcluded { plan.coverCount += set.coveredFiles }
            } catch {
                plan.problems.append("\(albumTitle(album.album)): \(error)")
            }
        }
        return plan
    }

    /// What a staged write can't do, for the sheet and the status line: its journal is its
    /// own, for a crash, and stays out of Edit > Undo (ADR 0146).
    static let stagedWrite = " These are staged files: Edit > Undo doesn't put them back."

    /// The question Apply's confirmation sheet asks.
    static func confirmation(_ plan: ApplyPlan, staged: Bool = false) -> (
        message: String, detail: String
    ) {
        let albums = plan.albumIDs.count
        let covers =
            plan.coverCount == 0 ? "" : " and \(DisplayText.count(plan.coverCount, "cover"))"
        let message =
            "Change \(number(plan.fieldCount)) tags\(covers) in \(number(plan.files.count)) files"
            + " of \(number(albums)) album\(albums == 1 ? "" : "s")?"
        var detail =
            "Each file gets the values the field mapping writes, as View Changes shows them."
            + (plan.coverCount == 0
                ? "" : " Each cover is its release's primary image from Discogs.")
            + (staged ? Self.stagedWrite : " Undo Tag Edit puts them all back.")

        if !plan.problems.isEmpty {
            detail +=
                "\n\n\(plan.problems.count) left out: "
                + plan.problems.prefix(3).joined(separator: "; ")
                + (plan.problems.count > 3 ? "; …" : "")
        }
        return (message, detail)
    }

    /// Lets an album whose files weren't all written be applied again.
    func reopen(_ plan: ApplyPlan, unwritten: Set<String>) {
        let failed = Set(unwritten.compactMap { plan.albumOfPath[$0] })
        guard !failed.isEmpty else { return }
        for index in albums.indices where failed.contains(albums[index].id) {
            albums[index].applied = false
            // Some of its files were written, so the count read before is old.
            forgetChangeCounts(of: albums[index].id)
        }
        status =
            "\(number(failed.count)) album\(failed.count == 1 ? "" : "s") not fully written;"
            + " Apply can try again"
        changed()
    }

    /// Hands the plan's edits to the writer: the user has confirmed them.
    func apply(_ plan: ApplyPlan) {
        guard !plan.files.isEmpty else { return }
        writes += 1
        let number = writes
        writing[number] = Writing(tags: plan.fieldCount, files: plan.files.count)
        if let staged {
            applyStaged(plan, staged) { [weak self] in
                self?.status = Self.wroteText(plan, staged: true)
                self?.wrote(number)
            }
        } else {
            write(
                plan.files,
                { [weak self] progress in
                    guard let self, writing[number] != nil else { return }
                    writing[number]?.progress = progress
                    changed()
                },
                { [weak self] unwritten in
                    guard let self else { return }
                    status = Self.wroteText(plan)
                    wrote(number)
                    reopen(plan, unwritten: unwritten)
                })
        }
        let applied = Set(plan.albumIDs)
        for index in albums.indices where applied.contains(albums[index].id) {
            albums[index].applied = true
        }
        // The line shows the write's progress until it ends, then `wroteText`.
        status = ""
        changed()
    }

    /// The status line once a plan is written.
    static func wroteText(_ plan: ApplyPlan, staged: Bool = false) -> String {
        "Wrote \(TaggerText.tagsToFiles(tags: plan.fieldCount, files: plan.files.count));"
            + (staged ? stagedWrite : " Undo Tag Edit puts them back")
    }

    /// The write `number` has finished, whatever it wrote.
    private func wrote(_ number: Int) {
        writing[number] = nil
        changed()
    }

    /// The writes running, as the window shows them.
    struct WriteProgress: Equatable {
        var tags: Int
        var files: Int
        /// The writes' progress as one; nil until one reports, and for a staged write.
        var progress: TagWriteProgress?

        /// "Writing 120 tags to 20 files: 3 of 20 written", or without the count before a
        /// report.
        var text: String {
            let what = "Writing \(TaggerText.tagsToFiles(tags: tags, files: files))"
            guard let progress else { return what + "…" }
            return
                "\(what): \(DisplayText.number(progress.written)) of \(DisplayText.number(files)) written"
        }
    }

    /// The writes running, nil when there are none.
    var writeProgress: WriteProgress? {
        guard !writing.isEmpty else { return nil }
        let values = Array(writing.values)
        let files = values.map(\.files).reduce(0, +)
        let reports = values.compactMap(\.progress)
        return WriteProgress(
            tags: values.map(\.tags).reduce(0, +), files: files,
            progress: reports.isEmpty ? nil : .combined(reports, total: files))
    }
}

/// `text` with its first letter capitalized, as an alert's message starts.
func sentence(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

/// "Artist – Title", or the title alone, as the album list and the problems name an album.
func albumTitle(_ album: DiscogsAlbum) -> String {
    album.artist.map { "\($0) – \(album.title)" } ?? album.title
}
