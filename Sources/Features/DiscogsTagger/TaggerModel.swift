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
    enum Scope {
        case library
        /// The albums of the tracks selected in the library window.
        case selection
        /// The albums none of whose tracks has a release id.
        case unmatched
        /// The albums Combine Albums for Tagging joined into one, which stay those albums
        /// until another scope is chosen (ADR 0179).
        case combined

        /// The scopes the Scope pop-up offers: a combination is opened by its command only,
        /// and the pop-up lists it only while it's open.
        static let listed: [Scope] = [.library, .selection, .unmatched]
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
        /// The library's albums `album` joins, in its files' order; empty for one of the
        /// library's own (ADR 0179).
        var sources: [DiscogsAlbum] = []

        var id: Int64 { album.id }
        /// How the album list and the problems name it: "Artist – Title", or each album it
        /// joins.
        var title: String { sources.isEmpty ? albumTitle(album) : CombinedAlbum.title(sources) }
        /// The album as it's matched and written: its files but those left out.
        var matched: DiscogsAlbum { Self.kept(album, leaving: leftOut) }
        var isRejected: Bool { review == .rejected }
        /// The album list's Review cell: what was done with the album in this session, or what
        /// the user decided.
        var reviewText: String {
            if applied { return "Written" }
            switch review {
            case .rejected: return "Rejected"
            case .chosen: return "Chosen"
            case nil: return ""
            }
        }

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
        /// Each combined album's sources, as `CombinedAlbum.text` names them (ADR 0179).
        var combined: [String] = []
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

    /// A tagger without Look Up Release, or with no album selected.
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
    var scope = Scope.library {
        didSet { if scope != .combined { combinedTracks = nil } }
    }
    /// The library files the open combination was made from, which Analyze joins the albums
    /// of again; nil when none is open.
    private(set) var combinedTracks: Set<Int64>?
    /// Set when a combination is opened, so its first Analyze forgets the files left out of
    /// an earlier one with the same first album, and so the same id.
    private var combinationOpened = false
    private(set) var albums: [Album] = [] {
        didSet {
            tierOrder = [:]
            keptArtworkGroups = nil
        }
    }
    /// Each tab's albums as places in `albums`, in list order, once sorted: the window lists
    /// them on every progress report, and sorting thousands each time stalls it.
    private var tierOrder: [TaggerTab: [Int]] = [:]
    /// `artworkGroups` once made, for the same reason: the window counts them on every refresh.
    private var keptArtworkGroups: [ArtworkGroup]?
    /// The files left out of each album, by album id, kept for the session so a new Analyze
    /// leaves them out too (ADR 0157).
    private var leftOutFiles: [Int64: Set<Int64>] = [:]
    /// The album being matched again, for a release chosen or a file left out or put back;
    /// one at a time.
    private(set) var rematchingID: Int64?
    var tab = TaggerTab.exact
    /// The album list's column and direction, from a click on its header.
    struct AlbumSort: Equatable {
        var column: TaggerColumn
        var ascending: Bool
    }
    /// Nil lists the albums by artist and then title.
    private(set) var albumSort: AlbumSort?
    /// The album the detail shows: the one clicked last. Setting it selects it alone.
    var selectedID: Int64? {
        didSet { selectedIDs = selectedID.map { [$0] } ?? [] }
    }
    /// The albums selected in the list, `selectedID` among them, which Reject and Apply act on
    /// when there are several.
    var selectedIDs: Set<Int64> = []
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
    /// It tells its second argument how far it has got, its third each step of Keep Files
    /// Organized after it, and its last the paths not written.
    var write: Write = { _, _, _, _ in }
    typealias Write =
        (
            [(path: String, edit: TagEdit)], @escaping (TagWriteProgress) -> Void,
            @escaping (OrganizeStep) -> Void, @escaping (Set<String>) -> Void
        ) -> Void
    /// The writes handed over and not yet finished, by number, which the window shows the
    /// progress of.
    private(set) var writing: [Int: Writing] = [:]
    private var writes = 0

    /// A write handed over and not yet finished: how many tags and files it writes, and how
    /// far it has got; nil before its first report, and for a staged write, which has none;
    /// and Keep Files Organized's step once its tags are written, nil before.
    struct Writing: Equatable {
        var tags: Int
        var files: Int
        var progress: TagWriteProgress?
        var step: OrganizeStep?
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
    /// A combined album's files get the release's title and album artist where its albums
    /// differ in them, so they become one album (ADR 0179).
    func changeSet(_ files: [AlbumFile], _ album: Album) -> AlbumChangeSet {
        var used = choices.keepExistingValues ? mapping.keepingExistingValues() : mapping
        if !album.sources.isEmpty {
            let combined = CombinedAlbum(album.sources)
            used = used.combining(titles: combined.titlesDiffer, artists: combined.artistsDiffer)
        }
        return Discogs.changeSet(
            for: files, match: album.match, mapping: used,
            fillingSortArtist: choices.fillSortArtist)
    }

    var isBusy: Bool { activity != .idle }
    /// What the tagger is doing, for the question at quit (ADR 0191); nil when idle.
    var activityLine: String? {
        switch activity {
        case .idle: nil
        case .analyzing(let done, let total):
            "Discogs tagger: analyzing \(number(done)) of \(number(total)) albums"
        case .reading(let done, let total):
            "Discogs tagger: reading \(number(done)) of \(number(total)) files"
        case .importing: "Importing the Discogs catalog"
        }
    }
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

    /// What the window's Get Artwork covers: the albums listed and not rejected whose files
    /// are tagged with a release id, or that Apply wrote one to this session.
    var artworkGroups: [ArtworkGroup] {
        if let keptArtworkGroups { return keptArtworkGroups }
        let groups = albums.filter { !$0.isRejected }.flatMap { album in
            Self.artworkGroups(album.matched, written: album.applied ? album.match.releaseID : nil)
        }
        keptArtworkGroups = groups
        return groups
    }

    /// The albums `tab` lists, in `albumSort`'s order; by artist and then title without one,
    /// and between albums it finds equal.
    func albums(in tab: TaggerTab) -> [Album] {
        if let order = tierOrder[tab] { return order.map { albums[$0] } }
        let order = albums.indices.filter { tab.lists(albums[$0].match) }.sorted { a, b in
            let (a, b) = (albums[a], albums[b])
            if let albumSort {
                let order = Self.compare(a, b, by: albumSort.column)
                if order != .orderedSame {
                    return order == (albumSort.ascending ? .orderedAscending : .orderedDescending)
                }
            }
            let artist = (a.album.artist ?? "").localizedStandardCompare(b.album.artist ?? "")
            return artist != .orderedSame
                ? artist == .orderedAscending
                : a.album.title.localizedStandardCompare(b.album.title) == .orderedAscending
        }
        tierOrder[tab] = order
        return order.map { albums[$0] }
    }

    /// Lists the albums by `column`, or by artist and then title for nil, as a click on the
    /// album list's header does.
    func sortAlbums(by sort: AlbumSort?) {
        guard sort != albumSort else { return }
        albumSort = sort
        tierOrder = [:]
        changed()
    }

    /// How two albums compare in the album list's `column`: the counts as numbers, no
    /// confidence under every one, the rest as Finder sorts names.
    private static func compare(_ a: Album, _ b: Album, by column: TaggerColumn)
        -> ComparisonResult
    {
        func numbers(_ x: Int, _ y: Int) -> ComparisonResult {
            x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
        }
        switch column {
        case .files: return numbers(a.album.tracks.count, b.album.tracks.count)
        case .confidence: return numbers(a.match.confidence ?? -1, b.match.confidence ?? -1)
        case .review: return a.reviewText.localizedStandardCompare(b.reviewText)
        default: return a.title.localizedStandardCompare(b.title)
        }
    }

    func count(_ tab: TaggerTab) -> Int { albums.count { tab.lists($0.match) } }

    var selected: Album? { albums.first { $0.id == selectedID } }

    /// The albums selected in the tab shown, in list order.
    var selectedAlbums: [Album] { albums(in: tab).filter { selectedIDs.contains($0.id) } }

    /// Whether the selected album's rows can be dragged to another track: its match is a guess.
    var canRemap: Bool {
        guard let tier = selected?.match.tier else { return false }
        return tier == .likely || tier == .incomplete
    }

    /// The tabs Apply writes: every one whose albums have a release (ADR 0184).
    static let appliedTabs: [TaggerTab] = [
        .exact, .likely, .safe, .titlesFit, .incomplete, .matched,
    ]

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
    /// albums are the scope's, or to them joined into one when `combining`; returns whether it
    /// did. Combining says why when it can't, since the user asked for it.
    func scopeToSelection(combining: Bool = false) -> Bool {
        guard !isBusy else {
            if combining {
                failed(
                    "The albums weren't combined",
                    ["The tagger is busy. Stop it or let it finish, then combine them again."])
            }
            return false
        }
        let selected: [Int64]
        do {
            selected = try selectedTracks()
        } catch {
            failed("The selected tracks couldn't be read", ["\(error)"])
            return false
        }
        guard !selected.isEmpty else {
            if combining {
                failed("No tracks are selected", ["Select albums in the library window first."])
            }
            return false
        }
        scope = combining ? .combined : .selection
        if combining {
            // A new combination, even over one open now.
            combinedTracks = Set(selected)
            combinationOpened = true
        }
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
            selection =
                switch scope {
                case .selection: Set(try selectedTracks())
                case .combined: combinedTracks ?? []
                case .library, .unmatched: []
                }
        } catch {
            return failed("The selected tracks couldn't be read", ["\(error)"])
        }
        if scope == .selection || scope == .combined, selection.isEmpty {
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
        let opened = combinationOpened
        combinationOpened = false
        work = Task {
            do {
                let all = try await effects.albums()
                var albums = all.filter { album in
                    switch scope {
                    case .library: true
                    case .selection, .combined:
                        album.tracks.contains { selection.contains($0.fileID) }
                    case .unmatched: album.tracks.allSatisfy { $0.releaseID == nil }
                    }
                }
                var reviews = try await effects.reviews()
                var sources: [DiscogsAlbum] = []
                if scope == .combined {
                    guard albums.count > 1 else { throw TooFewToCombine() }
                    let combined = CombinedAlbum(albums)
                    sources = combined.sources
                    albums = [combined.album]
                    if opened { leftOutFiles[combined.album.id] = nil }
                    // A release chosen for one of them alone fits only its own files.
                    let first = reviews[sources[0].id]
                    reviews[combined.album.id] =
                        sources.allSatisfy { reviews[$0.id] == first } ? first : nil
                }
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
                        chosen: chosen[album.id], leftOut: leftOut[index], sources: sources)
                }
                forgetChangeCounts()
                // A staged job's one album opens on its tier's tab, whichever it is.
                if staged != nil, let only = self.albums.first { tab = TaggerTab(only.match.tier) }
                if selected == nil { selectedID = self.albums(in: tab).first?.id }
                let seconds = Date().timeIntervalSince(started)
                status =
                    matches.count < albums.count
                    ? String(
                        format: "Analyzed %@ of %@ albums in %.1f s", number(matches.count),
                        number(albums.count), seconds)
                    : String(
                        format: "Analyzed %@ albums in %.1f s", number(albums.count), seconds)
                if alone { status += "; with no catalog, Both asked the Discogs API alone" }
                // The API alone keeps the albums it matched before it stopped (ADR 0190).
                if let apiStopped, source == .api {
                    status += "; Discogs stopped, so Analyze again to match the rest"
                    failed(
                        sentence(apiStopped.description),
                        [
                            "The albums the Discogs API matched before it stopped are shown."
                                + " Analyze again to match the rest: the albums it already"
                                + " searched for aren't searched again for a day."
                        ])
                } else if let apiStopped {
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
            } catch is TooFewToCombine {
                status = "Nothing to combine; the albums shown are the last run's"
                failed(
                    "Only one album is selected",
                    ["Select tracks of two or more albums in the library window to combine them."])
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

    /// A combined scope's selection that holds one album.
    private struct TooFewToCombine: Error {}

    /// Stops the Analyze, read or import running.
    func stop() {
        work?.cancel()
        reading?.cancel()
    }

    /// Returns once the work running has finished or stopped.
    func finished() async {
        await work?.value
        _ = try? await reading?.value  // The apply that started the read reports its error.
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

    /// Whether Look Up Release can search for the selected album: not while work runs. A
    /// staged job's searches the local catalog only (ADR 0178).
    var canLookUp: Bool { selected != nil && !isBusy && rematchingID == nil }

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

    /// Rejects the albums, so Apply leaves them out, or takes the rejections back; both are
    /// remembered. Taking one back remembers the release chosen for that album again.
    func setRejected(_ rejected: Bool, _ albumIDs: [Int64]) async {
        let wanted = Set(albumIDs)
        // One save per review: a rejection's, or each chosen release's when taken back.
        var groups: [(review: DiscogsReview?, albumIDs: Set<Int64>, files: [Int64])] = []
        for album in albums where wanted.contains(album.id) {
            let review: DiscogsReview? =
                rejected ? .rejected : album.chosen.map { DiscogsReview.chosen(releaseID: $0) }
            let files = album.album.tracks.map(\.fileID)
            if let at = groups.firstIndex(where: { $0.review == review }) {
                groups[at].albumIDs.insert(album.id)
                groups[at].files += files
            } else {
                groups.append((review, [album.id], files))
            }
        }
        defer { changed() }
        for group in groups {
            do {
                try await effects.review(group.review, group.files)
            } catch {
                return failed("The review couldn't be saved", ["\(error)"])
            }
            for index in albums.indices where group.albumIDs.contains(albums[index].id) {
                albums[index].review = group.review
            }
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
            return (set, CoverProblem.needsToken.line(for: album.title))
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
        case .failure(let problem): return (set, problem.line(for: album.title))
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

    /// The albums Apply in `tab` writes: those selected when several are, else all the tab's;
    /// of them, those with a release, not rejected and not written already.
    func applicable(_ tab: TaggerTab) -> [Album] {
        let listed = albums(in: tab)
        let selected = listed.filter { selectedIDs.contains($0.id) }
        return (selected.count > 1 ? selected : listed).filter {
            !$0.isRejected && !$0.applied && $0.match.release != nil
        }
    }

    /// Whether Apply in `tab` writes the albums selected in it rather than all of them.
    func appliesToSelection(in tab: TaggerTab) -> Bool {
        albums(in: tab).count { selectedIDs.contains($0.id) } > 1
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
                    "\(album.title): \(unread) file\(unread == 1 ? "" : "s")"
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
                if !album.sources.isEmpty {
                    plan.combined.append(CombinedAlbum.text(album.sources))
                }
                plan.files += edits
                for (path, _) in edits { plan.albumOfPath[path] = album.id }
                plan.fieldCount += set.files.flatMap(\.changes).count {
                    !album.excluded.contains($0.id)
                }
                if !album.coverExcluded { plan.coverCount += set.coveredFiles }
            } catch {
                plan.problems.append("\(album.title): \(error)")
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
        for combined in plan.combined {
            detail += "\n\n\(combined). Their files become one album of the release."
        }

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
                    // The writer reports twice a file, and each change redraws the window, so
                    // the first, about 200 more and the last, as Analyze's progress.
                    let steps = progress.read + progress.written
                    if steps == 1 || isReported(steps, of: 2 * progress.total) { changed() }
                },
                { [weak self] step in
                    guard let self, writing[number] != nil else { return }
                    // The renames report about each 1%, and the steps after them once each.
                    writing[number]?.step = step
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
        /// Keep Files Organized's step after the oldest write that has one, shown in place of
        /// the tags' count while no write is on its tags (ADR 0186).
        var step: OrganizeStep?

        /// "Writing 120 tags to 20 files: 3 of 20 written", or without the count before a
        /// report; or the organize's step: "Organizing files: 3 of 20 moved", "Updating Undo
        /// Tag Edit for the moved files…", "Updating the library…".
        var text: String {
            switch step {
            case .moving(let moving):
                return "Organizing files: \(DisplayText.number(moving.done)) of"
                    + " \(DisplayText.number(moving.total)) moved"
            case .updatingUndo: return "Updating Undo Tag Edit for the moved files…"
            case .updatingLibrary: return "Updating the library…"
            case nil: break
            }
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
        let onTags = values.contains { $0.progress != nil && $0.step == nil }
        let oldest = writing.keys.sorted().lazy.compactMap { self.writing[$0]?.step }.first
        let step = onTags ? nil : oldest
        return WriteProgress(
            tags: values.map(\.tags).reduce(0, +), files: files,
            progress: reports.isEmpty ? nil : .combined(reports, total: files), step: step)
    }
}

/// `text` with its first letter capitalized, as an alert's message starts.
func sentence(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

/// "Artist – Title", or the title alone, as the album list and the problems name an album.
func albumTitle(_ album: DiscogsAlbum) -> String {
    album.artist.map { "\($0) – \(album.title)" } ?? album.title
}
