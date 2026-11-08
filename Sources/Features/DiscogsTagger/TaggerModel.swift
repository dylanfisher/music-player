import Discogs
import DisplayText
import Foundation
import Library
import Settings
import TagWriter

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

    /// Where releases come from. Only the local catalog until phase 52; the window shows the
    /// others disabled.
    enum Source: CaseIterable {
        case catalog, api, both

        var isAvailable: Bool { self == .catalog }
    }

    enum CatalogState: Equatable {
        case checking
        case ready
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
        /// Handed to the writer in this session.
        var applied = false

        var id: Int64 { album.id }
        var isRejected: Bool { review == .rejected }
    }

    /// What Apply writes, for its confirmation sheet.
    struct ApplyPlan {
        var albumIDs: [Int64]
        var files: [(path: String, edit: TagEdit)]
        /// The album each file belongs to, by path.
        var albumOfPath: [String: Int64] = [:]
        var fieldCount: Int
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
        var match:
            @Sendable (
                [DiscogsAlbum], [Int64: Int], @escaping @Sendable (AlbumMatchProgress) -> Void
            ) async throws -> [AlbumMatch]
        var summaries: @Sendable ([Int]) async throws -> [ReleaseSummary]
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
    }

    private let effects: Effects
    private(set) var catalog = CatalogState.checking
    /// An import stopped, quit or killed before it finished, which Resume Import carries on.
    private(set) var unfinished: UnfinishedImport?
    private(set) var activity = Activity.idle
    /// What the last Analyze, import or Apply ended with, for the line under the toolbar.
    private(set) var status = ""
    var source = Source.catalog
    var scope = Scope.library
    private(set) var albums: [Album] = []
    var tab = MatchTier.exact
    var selectedID: Int64?
    var mapping: DiscogsMapping
    var savedMappings: [NamedDiscogsMapping]

    /// Called after anything shown changes.
    var changed: () -> Void = {}
    /// Called with a failure's message and details, for an alert.
    var failed: (String, [String]) -> Void = { _, _ in }
    /// The selected library tracks' ids, for the selection scope.
    var selectedTracks: () throws -> [Int64] = { [] }
    /// Writes the files' edits as one undoable batch; called only after the user confirmed.
    /// The completion hears the paths that weren't written.
    var write: ([(path: String, edit: TagEdit)], @escaping (Set<String>) -> Void) -> Void = {
        _, _ in
    }

    private var work: Task<Void, Never>?
    /// Apply's read of the files, which Stop cancels too.
    private var reading: Task<(files: [AlbumFile], problems: [String]), any Error>?
    /// Counts the runs started, so a late progress report of an older one is dropped.
    private var run = 0

    init(effects: Effects, mapping: DiscogsMapping, savedMappings: [NamedDiscogsMapping]) {
        self.effects = effects
        self.mapping = mapping
        self.savedMappings = savedMappings
    }

    var isBusy: Bool { activity != .idle }
    var canAnalyze: Bool { catalog == .ready && !isBusy }

    /// The albums of `tier`, by artist and then title.
    func albums(in tier: MatchTier) -> [Album] {
        albums.filter { $0.match.tier == tier }.sorted { a, b in
            let artist = (a.album.artist ?? "").localizedStandardCompare(b.album.artist ?? "")
            return artist != .orderedSame
                ? artist == .orderedAscending
                : a.album.title.localizedStandardCompare(b.album.title) == .orderedAscending
        }
    }

    func count(_ tier: MatchTier) -> Int { albums.count { $0.match.tier == tier } }

    var selected: Album? { albums.first { $0.id == selectedID } }

    /// Whether the selected album's rows can be dragged to another track: its match is a guess.
    var canRemap: Bool {
        guard let tier = selected?.match.tier else { return false }
        return tier == .likely || tier == .incomplete
    }

    /// The tiers Apply to All writes: those a match set can be trusted in after a review.
    static let appliedTiers: [MatchTier] = [.exact, .likely]

    // MARK: - The catalog

    /// Checks the catalog's file and any unfinished import, as the window opens and after an
    /// import.
    func checkCatalog() async {
        catalog = .checking
        changed()
        catalog = await effects.checkCatalog()
        unfinished = await effects.unfinishedImport()
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

    /// Matches the scope's albums with the catalog, off the main thread, taking each album's
    /// remembered review; the albums shown are replaced once it finishes.
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
        status = ""
        changed()
        let scope = scope
        let effects = effects
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
                let matches = try await effects.match(albums, chosen) { progress in
                    Task { @MainActor [self] in
                        guard self.run == current, case .analyzing = activity else { return }
                        activity = .analyzing(done: progress.albumsDone, total: progress.albumCount)
                        changed()
                    }
                }
                self.albums = zip(albums, matches).map { album, match in
                    Album(
                        album: album, match: match, review: reviews[album.id],
                        chosen: chosen[album.id])
                }
                if selected == nil { selectedID = self.albums(in: tab).first?.id }
                status = String(
                    format: "Analyzed %@ albums in %.1f s", number(albums.count),
                    Date().timeIntervalSince(started))
            } catch is CancellationError {
                status = "Analyze stopped; the albums shown are the last run's"
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
    }

    // MARK: - Reviewing an album

    /// Makes `releaseID` the album's match, rescored against its files, and remembers it.
    func choose(_ releaseID: Int, for albumID: Int64) async {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        let album = albums[index].album
        do {
            let match = try await effects.match([album], [albumID: releaseID]) { _ in }
            try await effects.review(.chosen(releaseID: releaseID), album.tracks.map(\.fileID))
            guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
            albums[index].match = match[0]
            albums[index].review = .chosen(releaseID: releaseID)
            albums[index].chosen = releaseID
            albums[index].excluded = []
            tab = match[0].tier
            changed()
        } catch {
            failed("The release couldn't be chosen", ["\(error)"])
        }
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

    /// What the mapping would change in the album's files, read now; nil for an album not
    /// shown.
    func changeSet(for albumID: Int64) async throws -> (AlbumChangeSet, problems: [String])? {
        guard let album = albums.first(where: { $0.id == albumID }) else { return nil }
        let (files, problems) = try await effects.read(album.album.tracks.map(\.fileID)) { _ in }
        return (Discogs.changeSet(for: files, match: album.match, mapping: mapping), problems)
    }

    /// Keeps the changes the user unticked in View Changes out of Apply.
    func setExcluded(_ excluded: Set<TagChange.ID>, for albumID: Int64) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        albums[index].excluded = excluded
        changed()
    }

    // MARK: - Apply

    /// The albums Apply to All in `tier` writes: those not rejected and not written already.
    func applicable(_ tier: MatchTier) -> [Album] {
        albums(in: tier).filter { !$0.isRejected && !$0.applied && $0.match.release != nil }
    }

    /// Reads the files of `albumIDs` and works out what Apply writes to them, with progress;
    /// nil when stopped.
    func plan(_ albumIDs: [Int64]) async -> ApplyPlan? {
        guard !isBusy else { return nil }
        let chosen = albums.filter { albumIDs.contains($0.id) }
        let fileIDs = chosen.flatMap { $0.album.tracks.map(\.fileID) }
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
            let albumFiles = album.album.tracks.compactMap { byID[$0.fileID] }
            guard albumFiles.count == album.album.tracks.count else {
                plan.problems.append("\(albumTitle(album.album)): not every file could be read")
                continue
            }
            let set = Discogs.changeSet(for: albumFiles, match: album.match, mapping: mapping)
            do {
                let edits = try set.edits { !album.excluded.contains($0) }
                guard !edits.isEmpty else { continue }
                plan.albumIDs.append(album.id)
                plan.files += edits
                for (path, _) in edits { plan.albumOfPath[path] = album.id }
                plan.fieldCount += set.files.flatMap(\.changes).count {
                    !album.excluded.contains($0.id)
                }
            } catch {
                plan.problems.append("\(albumTitle(album.album)): \(error)")
            }
        }
        return plan
    }

    /// The question Apply's confirmation sheet asks.
    static func confirmation(_ plan: ApplyPlan) -> (message: String, detail: String) {
        let albums = plan.albumIDs.count
        let message =
            "Change \(number(plan.fieldCount)) tags in \(number(plan.files.count)) files of "
            + "\(number(albums)) album\(albums == 1 ? "" : "s")?"
        var detail =
            "Each file gets the values the field mapping writes, as View Changes shows them."
            + " Undo Tag Edit puts them all back."
        if !plan.problems.isEmpty {
            detail +=
                "\n\n\(plan.problems.count) left out: "
                + plan.problems.prefix(3).joined(separator: "; ")
                + (plan.problems.count > 3 ? "; …" : "")
        }
        return (message, detail)
    }

    /// Lets an album whose files weren't all written be applied again.
    private func reopen(_ plan: ApplyPlan, unwritten: Set<String>) {
        let failed = Set(unwritten.compactMap { plan.albumOfPath[$0] })
        guard !failed.isEmpty else { return }
        for index in albums.indices where failed.contains(albums[index].id) {
            albums[index].applied = false
        }
        changed()
    }

    /// Hands the plan's edits to the writer: the user has confirmed them.
    func apply(_ plan: ApplyPlan) {
        guard !plan.files.isEmpty else { return }
        write(plan.files) { [weak self] unwritten in self?.reopen(plan, unwritten: unwritten) }
        for index in albums.indices where plan.albumIDs.contains(albums[index].id) {
            albums[index].applied = true
        }
        status =
            "Writing \(number(plan.fieldCount)) tags to \(number(plan.files.count)) files;"
            + " Undo Tag Edit puts them back"
        changed()
    }
}

/// "Artist – Title", or the title alone, as the album list and the problems name an album.
func albumTitle(_ album: DiscogsAlbum) -> String {
    album.artist.map { "\($0) – \(album.title)" } ?? album.title
}
