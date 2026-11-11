import AppKit
import Discogs
import Foundation
import Library
import Log
import Metadata
import Recommender
import Settings
import WindowPlacement

private let logger = moduleLogger()

/// Soulseek downloads (phase 54): the jobs music-recommender has, polled from launch to quit,
/// tagged and reported in the background, and the Downloads window, made on first show, where
/// the owner queues, reviews, approves and rejects them. App starts it once the service's
/// address and token are set, and stops it when they're cleared.
@MainActor
package final class Downloads {
    /// What the downloads need from the app.
    package struct Setup: Sendable {
        /// This Mac's name, as the service and the other Macs see it.
        package var machine: String
        package var service: DownloadsService
        /// The library index's file, which holds the outbox and the import ledger.
        package var databaseURL: URL
        /// The app's data folder, where the staged writes keep their journal.
        package var dataDirectory: URL
        /// The Discogs catalog's file, which may not exist on this Mac.
        package var catalog: URL
        /// The tagger's field mapping, which a staged write uses with every field replaced.
        package var mapping: DiscogsMapping
        /// The share the staging folder is on, whose albums can be upgraded; nil for a staging
        /// folder that isn't on a share.
        package var share: String?
        /// Finds the staging and library folders where they are now.
        package var places: @Sendable () async throws -> ImportPlaces
        /// `trashOrDelete`, giving its failure: how the old files an upgrade replaces go.
        package var trash: @Sendable ([URL]) async -> String?
        /// `LibraryWatcher.importMoves(lines:)`.
        package var carry: @Sendable ([(from: String, to: String)]) async throws -> MoveListImport
        /// `LibraryWatcher.rescan(directories:)`.
        package var rescan: @Sendable ([String]) -> Void

        package init(
            machine: String, service: DownloadsService, databaseURL: URL, dataDirectory: URL,
            catalog: URL, mapping: DiscogsMapping, share: String?,
            places: @escaping @Sendable () async throws -> ImportPlaces,
            trash: @escaping @Sendable ([URL]) async -> String?,
            carry:
                @escaping @Sendable ([(from: String, to: String)]) async throws
                -> MoveListImport,
            rescan: @escaping @Sendable ([String]) -> Void
        ) {
            self.machine = machine
            self.service = service
            self.databaseURL = databaseURL
            self.dataDirectory = dataDirectory
            self.catalog = catalog
            self.mapping = mapping
            self.share = share
            self.places = places
            self.trash = trash
            self.carry = carry
            self.rescan = rescan
        }
    }

    /// The downloads while the service is set: the model's polling, and the coordinator once
    /// the catalog has been checked.
    @MainActor
    final class Session {
        let setup: Setup
        let model: DownloadsModel
        var coordinator: DownloadsCoordinator?
        /// Whether this Mac has a catalog, so it can queue and tag.
        var canTag = false
        var problems: [String] = []
        /// slskd's web page, from the service's config, asked each time the window opens.
        var slskdPage: URL?

        init(_ setup: Setup, model: DownloadsModel) {
            self.setup = setup
            self.model = model
        }
    }

    /// The service's own limit on a machine's name.
    nonisolated static let machineNameCap = 64

    /// This Mac's name for leases and claims: the ID the library index names its sync log by,
    /// which is the same on every launch and on no other Mac. Reads the index off the calling
    /// thread.
    package nonisolated static func machineName(databaseURL: URL) async throws -> String {
        try await blockingFileWork {
            Result { String(try LibraryIndex(at: databaseURL).machineID().prefix(machineNameCap)) }
        }.get()
    }

    /// What the window says while the service isn't set.
    static let notSet =
        "music-recommender isn't set up on this Mac. Set its address in Settings > General, and"
        + " its token as \"recommender.token\" in the config file, to list its downloads."

    private(set) var session: Session?
    private(set) var controller: DownloadsWindow?
    /// An open sheet's controller, held while it shows.
    private var sheet: NSWindowController?
    /// The Approve… in progress, until its sheet shows or it stops.
    var reviewing: Task<Void, Never>?
    private var reviewCount = 0
    /// The albums Approve and Resume Here are moving into the library now, by run.
    private var imports: [Int: String] = [:]
    private var importCount = 0

    /// "Moving Artist - Title (2001) into the library", a line for each import running, for
    /// the question at quit (ADR 0191). The service's downloads go on without the app, and a
    /// tag run's lease and journal have it run again at the next launch, so neither is here.
    package var unfinishedWork: [String] {
        imports.sorted { $0.key < $1.key }.map { "Moving \($0.value) into the library" }
    }

    /// Runs `run`, the import of `album`, listed in `unfinishedWork` until it returns.
    func importing<T>(_ album: String, _ run: () async -> T) async -> T {
        importCount += 1
        let number = importCount
        imports[number] = album
        defer { imports[number] = nil }
        return await run()
    }

    /// The selected library tracks' ids, for From Library Selection.
    package var selectedTracks: () throws -> [Int64] = { [] }
    /// Opens the Discogs tagger on a staged job, with the staging folder's path; the tagger's
    /// Apply reports its verdict through the closure, with the release it wrote; no verdict
    /// when it wrote only some of the files, whose release is recorded all the same.
    package var openInTagger:
        (
            StagedJob, String,
            @escaping @Sendable (AutoTagRun.Verdict?, _ releaseID: Int) -> Void
        ) -> Void = { _, _, _ in }

    /// The window's column widths as they were left, set before it first shows, and what
    /// saves them as a column is resized.
    package var columnWidths = ColumnWidths()
    package var columnWidthsChanged: (ColumnWidths) -> Void = { _ in }

    /// Shows files in the Finder, and opens a web page; tests stand in for both.
    var showInFinder: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    var openPage: (URL) -> Void = { url in
        if !NSWorkspace.shared.open(url) { logger.error("couldn't open \(url)") }
    }

    /// The status bar's item, which App puts on the bar's left, after the activity text.
    let statusItem = DownloadsStatusItem()
    /// How the status item shows the downloads, `appearance.downloadsStatusStyle`.
    package var statusStyle = DownloadsStatusStyle.progress {
        didSet { showStatus() }
    }
    /// Hears a style picked from the status item's menu, to save it.
    package var styleChosen: (DownloadsStatusStyle) -> Void = { _ in }
    /// Whether the status bar is in view, which sets the polling's pace.
    private var statusBarShown = false

    /// Approve Safe Matches Automatically, `import.autoApproveSafeMatches`: the owner's
    /// standing confirmation for each staged job whose plan asks nothing (ADR 0193). Turning it
    /// on looks at every staged job again, those left for review before too.
    package var autoApprove = false {
        didSet {
            guard autoApprove != oldValue else { return }
            if autoApprove { session?.model.forgetLeftForReview() }
            refresh()
            approveSafe()
        }
    }
    /// Hears the window's box for it turned on or off, to save it.
    package var autoApproveChosen: (Bool) -> Void = { _ in }
    /// The job being approved unasked, and its task.
    private(set) var approving: (job: Int, task: Task<Void, Never>)?
    private var approvingCount = 0
    /// Works out Approve's plan for a job approved unasked, checked; tests stand in for it.
    var checkedPlan: @MainActor (DownloadJob, ImportPlaces, Session) async throws -> ApprovalPlan =
        {
            job, places, session in
            let setup = session.setup
            return try await ApprovalPlan.build(
                job, places: places, databaseURL: setup.databaseURL,
                catalog: session.canTag ? setup.catalog : nil
            ).checked(places: places)
        }

    /// Upgrade to FLAC Automatically, `downloads.autoUpgrade` (ADR 0200): keeps up to
    /// `autoUpgradesInFlight` upgrades of its own on the service while the app is open.
    /// Turning it off stops a pass before its next call; the jobs queued carry on.
    package var autoUpgrade = false {
        didSet {
            guard autoUpgrade != oldValue else { return }
            refresh()
            upgradeAutomatically()
        }
    }
    /// `downloads.autoUpgradesInFlight`.
    package var autoUpgradesInFlight = AppSettings().autoUpgradesInFlight.defaultValue {
        didSet { upgradeAutomatically() }
    }
    /// Hears the window's box for it turned on or off, to save it.
    package var autoUpgradeChosen: (Bool) -> Void = { _ in }
    /// The pass running, and whether a poll or a change came during it, which runs another.
    var upgrading: Task<Void, Never>?
    var upgradeAgain = false
    /// The jobs Approve Safe Matches Automatically found a lossy-origin finding in, by epoch,
    /// which the upgrader requeues when they're its own; each pass keeps only its own.
    var notClean: Set<AutoUpgradeJob> = []
    /// The jobs it queued that the index didn't record, recorded again at each pass.
    var unrecorded: Set<AutoUpgradeJob> = []
    /// The candidates the last pass read, for a pass while nothing they're chosen by changed.
    var candidatesRead: AutoUpgrades.CandidatesRead?
    /// The releases whose snapshot couldn't be built, left until the session stops.
    var unqueueable: Set<Int> = []
    /// The clock the misses are dated by; tests stand in for it.
    var now: () -> Date = Date.init
    /// The albums the upgrader may queue, read from the index off the main thread; tests
    /// stand in for it.
    var upgradeCandidates: @Sendable (URL, String) async throws -> [UpgradeCandidate] = {
        database, share in
        try await blockingFileWork {
            Result { try LibraryIndex(at: database).upgradeCandidates(onShare: share) }
        }.get()
    }
    /// Builds a release's snapshot from the catalog off the main thread; tests stand in for it.
    var releaseSnapshot: @Sendable (Int, URL) async throws -> ReleaseSnapshot = {
        release, catalog in
        try await blockingFileWork {
            Result { try ReleaseSnapshot.queueable(releaseID: release, catalogAt: catalog) }
        }.get()
    }

    package init() {
        statusItem.clicked = { [weak self] in self?.show() }
        statusItem.styleChosen = { [weak self] in self?.styleChosen($0) }
    }

    package var statusView: NSView { statusItem }

    /// Tells the polling whether the status bar, and so the item, is in view.
    package func setStatusBarShown(_ shown: Bool) {
        statusBarShown = shown
        session?.model.setStatusShown(shown)
    }

    private func showStatus() {
        statusItem.show(
            session.flatMap { DownloadsStatus($0.model.jobs.rows.values) }, style: statusStyle)
    }

    /// The window, once shown.
    package var window: NSWindow? { controller?.window }

    /// Starts polling with `setup`, in place of any session before it.
    package func start(_ setup: Setup) {
        stop()
        let model = DownloadsModel(service: setup.service, machine: setup.machine)
        let session = Session(setup, model: model)
        self.session = session
        model.changed = { [weak self] in self?.refresh() }
        Task {
            let catalog = setup.catalog
            let canTag = await blockingFileWork { () -> Bool in
                do {
                    _ = try CatalogStatus(at: catalog)
                    return true
                } catch {
                    logger.notice("no Discogs catalog to queue or tag downloads with: \(error)")
                    return false
                }
            }
            guard self.session === session else { return }
            session.canTag = canTag
            let coordinator = DownloadsCoordinator(
                machine: setup.machine, databaseURL: setup.databaseURL,
                effects: Self.effects(setup, canTag: canTag))
            session.coordinator = coordinator
            model.took = { jobs in
                Task {
                    await coordinator.take(jobs)
                    let problems = await coordinator.problems
                    let tagged = await coordinator.taggedAs()
                    guard self.session === session else { return }
                    // Changes the rows, and calls `changed`, only when it's new.
                    model.setTagged(tagged)
                    self.approveSafe()
                    self.upgradeAutomatically()
                    // The poll refreshed the rows; only a new problem changes what shows.
                    guard problems != session.problems else { return }
                    session.problems = problems
                    self.refresh()
                }
            }
            // Set before the start, whose first poll is the one either would ask for.
            if controller?.window?.isVisible == true { model.setWindowOpen(true) }
            model.setStatusShown(statusBarShown)
            model.start()
            refresh()
        }
        refresh()
    }

    /// Stops polling, at quit or when the service's settings are cleared.
    package func stop() {
        cancelReview()
        approving?.task.cancel()
        approving = nil
        upgrading?.cancel()
        upgrading = nil
        notClean = []
        unrecorded = []
        unqueueable = []
        candidatesRead = nil
        session?.model.stop()
        session = nil
        refresh()
    }

    /// The coordinator's effects for `setup`: AutoTag only with a catalog.
    nonisolated static func effects(_ setup: Setup, canTag: Bool) -> DownloadsCoordinator.Effects {
        let catalog = setup.catalog
        let mapping = setup.mapping
        let places = setup.places
        let tagging: @Sendable (StagedJob) async throws -> AutoTagRun = { job in
            let root = try await places().stagingRoot
            return try await autoTag(job, stagingRoot: root, catalogAt: catalog, mapping: mapping)
        }
        return DownloadsCoordinator.Effects(
            service: setup.service,
            sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9)) },
            autoTag: canTag ? tagging : nil,
            recover: {
                let root: String
                do {
                    root = try await places().stagingRoot
                } catch {
                    return ["the staging folder wasn't found: \(error)"]
                }
                let writer = StagedWriter(stagingRoot: root, dataDirectory: setup.dataDirectory)
                let report = await blockingFileWork { writer.recoverInterrupted() }
                return report.failures.map(\.description)
            },
            write: { run in
                let root: String
                do {
                    root = try await places().stagingRoot
                } catch {
                    return .error(["the staging folder wasn't found: \(error)"])
                }
                let writer = StagedWriter(stagingRoot: root, dataDirectory: setup.dataDirectory)
                return await blockingFileWork { writer.write(run, mapping: mapping) }
            },
            importRun: { job, deliver in
                let found: ImportPlaces
                do {
                    found = try await places()
                } catch {
                    return .refused("the staging or library folder wasn't found: \(error)")
                }
                let index: LibraryIndex
                do {
                    index = try LibraryIndex(at: setup.databaseURL)
                } catch {
                    return .refused("the library couldn't be opened: \(error)")
                }
                return await ImportRun(
                    index: index, move: found.move, trash: setup.trash, carry: setup.carry,
                    rescan: setup.rescan, deliver: deliver
                ).run(job)
            })
    }

    // MARK: - The window

    /// Shows the window, making it the first time, where it was left (ADR 0158). With
    /// `offeringSelection`, File > Downloads…, two or more library tracks selected now open
    /// From Library Selection for them once the window can queue. Without it, an offer waiting
    /// stays.
    package func show(offeringSelection: Bool = false) {
        let making = self.controller == nil
        let controller = self.controller ?? makeWindow()
        if making {
            controller.window?.keepsFrame(as: DownloadsWindow.title)
            controller.keepWidths(columnWidths)
        }
        if offeringSelection { offeredTracks = currentSelection() }
        refresh(opening: true)
        controller.showWindow(nil)
        session?.model.setWindowOpen(true)
        offerSelection()
        askForSlskd()
    }

    /// Asks the service where slskd's page is, for Open slskd, each time the window opens, so
    /// a change to the service's config shows on the next.
    private func askForSlskd() {
        guard let session else { return }
        let page = session.setup.service.slskdPage
        Task {
            do throws(RecommenderError) {
                let found = try await page()
                guard self.session === session else { return }
                session.slskdPage = found
            } catch {
                logger.info("slskd's page wasn't found: \(error)")
            }
            refresh()
        }
    }

    /// Opens slskd's web page, where the service says it is.
    func openSlskd() {
        guard let page = session?.slskdPage else { return }
        openPage(page)
    }

    /// The tracks selected when File > Downloads… opened the window, whose From Library
    /// Selection opens once the window can queue: after the catalog check and the first
    /// answer. Any other sheet on the window drops it, as does closing the window.
    private(set) var offeredTracks: [Int64]?
    /// How many sheets the window has begun, so an offer that finds one begun since gives way.
    private var sheetsBegun = 0
    private var sheetObserver: (any NSObjectProtocol)?

    /// The tracks selected in the library; nil for none or one, which is a track picked to play
    /// rather than an album to download, or a selection that can't be read.
    private func currentSelection() -> [Int64]? {
        do {
            let tracks = try selectedTracks()
            return tracks.count < 2 ? nil : tracks
        } catch {
            logger.notice("the library's selection couldn't be read: \(error)")
            return nil
        }
    }

    /// Opens From Library Selection for the tracks offered, once the window can queue and has
    /// no sheet up.
    private func offerSelection() {
        guard let tracks = offeredTracks, let session, session.canTag, sheet == nil,
            session.model.connection == .answering, let window = controller?.window,
            window.isVisible, window.attachedSheet == nil
        else { return }
        offeredTracks = nil
        queueFromSelection(tracks, asked: false)
    }

    func makeWindow() -> DownloadsWindow {
        let made = DownloadsWindow()
        made.applies = { [weak self] action, row in self?.applies(action, row) ?? false }
        made.act = { [weak self] action, row in self?.act(action, row) }
        made.add = { [weak self] addition in self?.add(addition) }
        made.openSlskd = { [weak self] in self?.openSlskd() }
        made.autoApproveChanged = { [weak self] on in
            self?.autoApproveChosen(on)
            // The box shows the setting, which a save that failed left as it was.
            self?.refresh()
        }
        made.autoUpgradeChanged = { [weak self] on in
            self?.autoUpgradeChosen(on)
            self?.refresh()
        }
        made.columnsResized = { [weak self] widths in
            self?.columnWidths = widths
            self?.columnWidthsChanged(widths)
        }
        made.visibilityChanged = { [weak self] open in
            if !open {
                self?.cancelReview()
                self?.offeredTracks = nil
            }
            self?.session?.model.setWindowOpen(open)
        }
        if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
        sheetObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willBeginSheetNotification, object: made.window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sheetsBegun += 1
                self?.offeredTracks = nil
            }
        }
        controller = made
        return made
    }

    /// Shows what changed: the status item always, the window only while it's open, or with
    /// `opening`, just before it shows, so it opens on the rows as they are.
    private func refresh(opening: Bool = false) {
        showStatus()
        guard let controller, opening || controller.window?.isVisible == true else { return }
        defer { offerSelection() }
        controller.showSlskd(session?.slskdPage)
        controller.showAutoApprove(autoApprove)
        controller.showAutoUpgrade(autoUpgrade)
        guard let session else {
            return controller.show([], status: Self.notSet, canAdd: false)
        }
        let status = DownloadsModel.status(
            session.model.connection, canAdd: session.canTag || session.coordinator == nil,
            problems: session.problems,
            formatted: {
                DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short)
            })
        controller.show(
            session.model.rows, status: status,
            canAdd: session.canTag && sheet == nil && session.model.connection == .answering)
    }

    func applies(_ action: DownloadAction, _ row: DownloadRow) -> Bool {
        guard let session, sheet == nil, approving?.job != row.id,
            let job = session.model.job(row.id)
        else { return false }
        return DownloadAction.applies(
            action, to: job, machine: session.setup.machine,
            answering: session.model.connection == .answering, canTag: session.canTag)
    }

    // MARK: - Actions

    private func act(_ action: DownloadAction, _ row: DownloadRow) {
        guard let session, let job = session.model.job(row.id) else { return }
        switch action {
        case .approve: startReview(job, session, resuming: false)
        case .resumeHere: startReview(job, session, resuming: true)
        case .reject:
            confirm(
                "Reject \(row.album)?",
                "music-recommender deletes its staged folder. Nothing in the library changes.",
                "Reject"
            ) {
                Task {
                    guard let coordinator = session.coordinator else { return }
                    if let problem = await coordinator.reject(job) {
                        self.alert("The rejection wasn't sent", [problem])
                    }
                    await session.model.poll()
                }
            }
        case .cancel:
            confirm(
                "Cancel the download of \(row.album)?",
                "music-recommender stops it and deletes what it got.", DownloadAction.cancel.title
            ) {
                Task {
                    if let problem = await session.model.cancel(job.id) {
                        self.alert("The download wasn't cancelled", [problem])
                    }
                }
            }
        case .retry: retry(job, row, session)
        case .revealInFinder: reveal(job, session)
        case .openInTagger:
            guard let coordinator = session.coordinator else { return }
            let heading = "\(row.album) can't open in the tagger"
            let catalog = session.canTag ? session.setup.catalog : nil
            Task {
                if let refusal = await Self.taggerRefusal(job, catalog: catalog) {
                    return alert(heading, [refusal])
                }
                guard let staged = await coordinator.stagedJob(job) else {
                    return alert(heading, ["music-recommender hasn't staged its files"])
                }
                let root: String
                do {
                    root = try await session.setup.places().stagingRoot
                } catch {
                    return alert("The staging folder wasn't found", ["\(error)"])
                }
                openInTagger(staged, root) { verdict, release in
                    Task {
                        guard let verdict else {
                            // Some files were written: their release is kept, nothing reported.
                            await coordinator.wrote(job, release: release, stagingRoot: root)
                            return await session.model.poll()
                        }
                        let problem = await coordinator.resolved(
                            job, verdict, release: release, stagingRoot: root)
                        await MainActor.run {
                            if let problem { self.alert("The tagging wasn't reported", [problem]) }
                        }
                        await session.model.poll()
                    }
                }
            }
        }
    }

    /// Why `job` can't open in the tagger, or nil when it can: it needs one staged folder, the
    /// format the service downloaded, and its release in the catalog at `catalog`, nil on a Mac
    /// without one. Reads the catalog off the main thread.
    nonisolated static func taggerRefusal(_ job: DownloadJob, catalog: URL?) async -> String? {
        guard let path = job.stagedPath else {
            return "music-recommender hasn't said where it staged the files"
        }
        guard job.stagedFolder != nil else { return DownloadJob.notOneFolder(path) }
        guard job.candidate != nil else {
            return "music-recommender hasn't said what format it downloaded"
        }
        guard let catalog else { return "this Mac has no Discogs catalog to tag with" }
        let release = job.release.releaseID
        return await blockingFileWork { () -> String? in
            do {
                guard try Catalog(at: catalog).release(id: release) != nil else {
                    return ReleaseSnapshot.Problem.notInCatalog(releaseID: release).description
                }
                return nil
            } catch {
                return "the Discogs catalog couldn't be read: \(error)"
            }
        }
    }

    /// Shows `job`'s staged folder in the Finder, found where the staging folder is now. A
    /// folder the service names outside the staging folder, by its name or by a link, is
    /// refused.
    func reveal(_ job: DownloadJob, _ session: Session) {
        guard let path = job.stagedPath else { return }
        guard let folder = job.stagedFolder else {
            return alert("The staged folder wasn't shown", [DownloadJob.notOneFolder(path)])
        }
        let places = session.setup.places
        Task {
            let root: String
            do {
                root = try await places().stagingRoot
            } catch {
                return alert("The staging folder wasn't found", ["\(error)"])
            }
            let url = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(folder, isDirectory: true)
            let found = await blockingFileWork { () -> String? in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return "\(url.path) is missing"
                }
                let real = url.resolvingSymlinksInPath().path
                let realRoot = URL(fileURLWithPath: root, isDirectory: true)
                    .resolvingSymlinksInPath().path
                return isPath(real, inOrAt: realRoot) && real != realRoot
                    ? nil : "\(url.path) leads outside the staging folder, to \(real)"
            }
            if let found { return alert("The staged folder wasn't shown", [found]) }
            showInFinder([url])
        }
    }

    /// Starts `review` unless one is in flight, so a quick second click leaves the first
    /// cancellable.
    func startReview(_ job: DownloadJob, _ session: Session, resuming: Bool) {
        guard reviewing == nil else { return }
        reviewCount += 1
        let number = reviewCount
        reviewing = Task {
            await review(job, session, resuming: resuming)
            // Whatever way it ended, a later Approve may start; unless this one was replaced.
            if reviewCount == number { reviewing = nil }
        }
    }

    /// Stops the Approve… still checking the staged files, which gives its claim back.
    func cancelReview() {
        reviewing?.cancel()
        reviewing = nil
    }

    /// Whether a review's claim needs giving back, and whether its sheet has ended, which the
    /// sheet's end and the review's steps both read.
    @MainActor
    private final class ReviewState {
        /// The claim is this Mac's, or the review is a Resume Here, which took none.
        var claimed: Bool
        var ended = false

        init(claimed: Bool) { self.claimed = claimed }
    }

    /// Approve… and Resume Here: shows the sheet at once, saying what it's preparing; takes the
    /// review claim (Resume Here takes it over when it runs); works out the plan, which fills
    /// the sheet, then the lossy-origin check; and runs the import once the sheet approves it
    /// (ADR 0169). Every way out before the import gives a claim Approve took back. Returns
    /// once the check is done, or the review stops.
    func review(_ job: DownloadJob, _ session: Session, resuming: Bool) async {
        guard let coordinator = session.coordinator else { return }
        let setup = session.setup
        var job = job
        let id = job.id
        let giveUp = { @MainActor @Sendable in
            guard !resuming else { return }
            do throws(RecommenderError) {
                session.model.took(try await coordinator.releaseReview(id))
            } catch {
                logger.info("job \(id)'s review claim not given up: \(error)")
            }
        }
        let state = ReviewState(claimed: resuming)
        let album = DownloadRow.album(job.release)
        let approve = ApproveSheet(
            job: job, album: DownloadRow.album(job.release), resuming: resuming,
            taggedAs: session.model.taggedAs(id))
        approve.preparing(resuming ? ApproveSheet.findingStep : ApproveSheet.claimingStep)
        let shown = present(approve) {
            guard let approved = approve.result else {
                state.ended = true
                self.cancelReview()
                // A claim still being asked for is given back once it's answered.
                if state.claimed { Task { await giveUp() } }
                return
            }
            Task {
                let outcome = await self.importing(album) {
                    resuming
                        ? await coordinator.resumeHere(approved)
                        : await coordinator.approve(approved)
                }
                switch outcome {
                case .imported: break
                case .refused(let why): self.alert("The album wasn't imported", [why])
                case .failed(let stage, let why):
                    self.alert(
                        "The import stopped at \(stage.rawValue)",
                        [why, "Retry goes on from there."])
                }
                await session.model.poll()
            }
        }
        // No sheet, no claim: the window isn't up, or a sheet is.
        guard shown else { return }
        // Ends the sheet, whose end gives the claim back, and says why.
        let stop = { (message: String, details: [String]) in
            approve.endSheet()
            self.alert(message, details)
        }
        let stopped = { state.ended || Task.isCancelled }
        if !resuming {
            do throws(RecommenderError) {
                job = try await coordinator.claimReview(job.id)
            } catch {
                if stopped() {
                    approve.endSheet()
                    // The service may have taken the claim before the request was cancelled;
                    // it goes back from a task of its own, as this one's requests are cancelled.
                    Task { await giveUp() }
                    return
                }
                return stop("Another Mac may be reviewing this album", [error.description])
            }
            state.claimed = true
            if stopped() {
                guard state.ended else { return approve.endSheet() }
                Task { await giveUp() }
                return
            }
            session.model.took(job)
            guard DownloadRow(job, machine: setup.machine)?.canApprove == true else {
                return stop(
                    "This album can't be approved now",
                    ["It's \(job.state.rawValue), tagged \(job.tagging.status.rawValue)."])
            }
            approve.preparing(ApproveSheet.findingStep)
        }
        let places: ImportPlaces
        do {
            places = try await setup.places()
        } catch {
            return stop("The staging or library folder wasn't found", ["\(error)"])
        }
        guard !stopped() else { return approve.endSheet() }
        approve.preparing(ApproveSheet.planningStep)
        let plan = await ApprovalPlan.build(
            job, places: places, databaseURL: setup.databaseURL,
            catalog: session.canTag ? setup.catalog : nil)
        guard !stopped() else { return approve.endSheet() }
        approve.show(plan)
        guard plan.checking else { return }
        do {
            let checked = try await plan.checked(places: places)
            guard !stopped() else { return approve.endSheet() }
            approve.show(checked)
        } catch {
            approve.endSheet()
        }
    }

    // MARK: - Approving unasked

    /// Whether Approve Safe Matches Automatically looks at `job`: staged, tagged clean, and
    /// reviewed on no other Mac.
    nonisolated static func mayApproveUnasked(_ job: DownloadJob, machine: String) -> Bool {
        job.state == .staged && job.tagging.status == .clean
            && (job.review == nil || job.review?.machine == machine)
    }

    /// Why a job whose files the owner tagged as another release isn't approved unasked.
    static let taggedAsAnotherRelease =
        "its files were tagged as another release in the tagger, which Approve shows"

    /// With Approve Safe Matches Automatically on, approves the first job it may look at that
    /// it hasn't left for review, one at a time and none during an Approve… on this Mac, then
    /// the next.
    func approveSafe() {
        guard autoApprove, approving == nil, reviewing == nil, let session,
            session.coordinator != nil, session.model.connection == .answering
        else { return }
        let model = session.model
        let machine = session.setup.machine
        guard
            let job = model.jobs.rows.values.sorted(by: { $0.id < $1.id }).first(where: {
                Self.mayApproveUnasked($0, machine: machine) && model.leftForReview[$0.id] == nil
            })
        else { return }
        approvingCount += 1
        let number = approvingCount
        approving = (
            job.id,
            Task {
                await approveUnasked(job, session)
                guard approvingCount == number else { return }
                approving = nil
                refresh()
                approveSafe()
            }
        )
        refresh()
    }

    /// Approve's steps without its sheet (ADR 0193): takes the review claim, works out the plan
    /// and its check, and runs the import Approve would when the plan asks nothing; else gives
    /// the claim back and leaves the job staged, saying why in its row.
    func approveUnasked(_ listed: DownloadJob, _ session: Session) async {
        guard let coordinator = session.coordinator else { return }
        let model = session.model
        let setup = session.setup
        let id = listed.id
        let leave = { (why: String) in model.leave(id, why) }
        if model.taggedAs(id) != nil { return leave(Self.taggedAsAnotherRelease) }
        let giveBack = { @MainActor @Sendable in
            do throws(RecommenderError) {
                model.took(try await coordinator.releaseReview(id))
            } catch {
                logger.info("job \(id)'s review claim not given up: \(error)")
            }
        }
        // From a task of its own once this one is cancelled, whose requests are cancelled too.
        let giveBackApart = { _ = Task { await giveBack() } }
        let job: DownloadJob
        do throws(RecommenderError) {
            job = try await coordinator.claimReview(id)
        } catch {
            return leave("the review claim wasn't taken: \(error)")
        }
        model.took(job)
        guard !Task.isCancelled else { return giveBackApart() }
        guard DownloadRow(job, machine: setup.machine)?.canApprove == true else {
            await giveBack()
            return leave("it's \(job.state.rawValue), tagged \(job.tagging.status.rawValue)")
        }
        let places: ImportPlaces
        do {
            places = try await setup.places()
        } catch {
            await giveBack()
            return leave("the staging or library folder wasn't found: \(error)")
        }
        let plan: ApprovalPlan
        do {
            // Throws only when cancelled.
            plan = try await checkedPlan(job, places, session)
        } catch {
            return giveBackApart()
        }
        guard !Task.isCancelled else { return giveBackApart() }
        switch plan.unasked {
        case .left(let why):
            await giveBack()
            leave(why)
        case .notClean(let why):
            await giveBack()
            leave(why)
            if let epoch = model.jobs.epoch {
                notClean.insert(
                    AutoUpgradeJob(epoch: epoch, jobID: id, releaseID: job.release.releaseID))
            }
            upgradeAutomatically()
        case .approved(let approved):
            let outcome = await importing(DownloadRow.album(job.release)) {
                await coordinator.approve(approved)
            }
            switch outcome {
            case .imported: logger.notice("job \(id) approved unasked")
            case .refused(let why):
                await giveBack()
                leave(why)
            case .failed(let stage, let why):
                leave("the import stopped at \(stage.rawValue): \(why)")
            }
        }
        await model.poll()
    }

    private func retry(_ job: DownloadJob, _ row: DownloadRow, _ session: Session) {
        let send = { (policy: FormatPolicy?) in
            _ = Task {
                if let problem = await session.model.retry(job.id, policy: policy) {
                    self.alert("The job wasn't started again", [problem])
                }
            }
        }
        guard DownloadAction.retrySearches(job) else { return send(nil) }
        guard let window = controller?.window else { return }
        let policies = FormatPolicy.offered(upgrade: job.source == .upgrade)
        let popUp = formatPopUp(policies)
        popUp.selectItem(at: policies.firstIndex(of: job.formatPolicy) ?? 0)
        let question = NSAlert()
        question.messageText = "Search again for \(row.album)?"
        question.informativeText = "Choose the format to ask for."
        question.accessoryView = popUp
        question.addButton(withTitle: DownloadAction.retry.title)
        question.addButton(withTitle: "Cancel")
        question.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            send(policies[popUp.indexOfSelectedItem])
        }
    }

    // MARK: - Adding

    /// Queues by `addition`.
    private func add(_ addition: DownloadAddition) {
        guard let session, session.canTag else { return }
        let setup = session.setup
        switch addition {
        case .upgrades:
            guard let share = setup.share else {
                return alert(
                    "Upgrades need the staging folder on the library's share",
                    ["An upgrade's old files are kept by their path on the share."])
            }
            Task {
                let found = await blockingFileWork {
                    Result { () throws -> ([UpgradeCandidate], Set<Int>) in
                        let index = try LibraryIndex(at: setup.databaseURL)
                        return (
                            try index.upgradeCandidates(onShare: share),
                            try index.neverUpgradeReleases()
                        )
                    }
                }
                let candidates: [UpgradeCandidate]
                let never: Set<Int>
                do {
                    (candidates, never) = try found.get()
                } catch {
                    return alert("The library couldn't be read", ["\(error)"])
                }
                chooseAndQueue(
                    heading: "Upgrades",
                    note:
                        "Lossy albums whose every track carries one Discogs release id. A lossless"
                        + " copy replaces each; Approve deletes the old files. Never Upgrade"
                        + " keeps an album out of the automatic upgrades.",
                    QueueChoice.upgrades(candidates, never: never), upgrade: true,
                    tickingAll: false, other: QueueChoice.neverUpgradeTitle
                ) { marked in
                    self.write("The albums weren't marked Never Upgrade") { index in
                        try index.setNeverUpgrade(true, releases: marked.compactMap(\.releaseID))
                    }
                }
            }
        case .notFound:
            guard let share = setup.share else {
                return alert(
                    "Upgrades need the staging folder on the library's share",
                    ["An upgrade's old files are kept by their path on the share."])
            }
            Task {
                let found = await blockingFileWork {
                    Result { () throws -> [QueueChoice] in
                        let index = try LibraryIndex(at: setup.databaseURL)
                        return QueueChoice.setAside(
                            try index.upgradeCandidates(onShare: share),
                            misses: try index.upgradeMisses())
                    }
                }
                let choices: [QueueChoice]
                do {
                    choices = try found.get()
                } catch {
                    return alert("The library couldn't be read", ["\(error)"])
                }
                guard !choices.isEmpty else {
                    return alert("Nothing to queue", ["No automatic upgrade was set aside."])
                }
                let sheet = QueueSheet(
                    heading: "Upgrades Not Found",
                    note: Self.notFoundNote(autoUpgrade: autoUpgrade),
                    choices: choices, policies: [.flac], tickingAll: false,
                    button: Self.queueAgainTitle)
                present(sheet) {
                    guard let again = sheet.result?.choices else { return }
                    self.write("The albums weren't queued again") { index in
                        try index.clearUpgradeMisses(releases: again.compactMap(\.releaseID))
                    } then: {
                        self.upgradeAutomatically()
                    }
                }
            }
        case .fromSelection:
            let selected: [Int64]
            do {
                selected = try selectedTracks()
            } catch {
                return alert("The selection couldn't be read", ["\(error)"])
            }
            guard !selected.isEmpty else {
                return alert(
                    "No tracks are selected", ["Select an album's tracks in the library first."])
            }
            queueFromSelection(selected, asked: true)
        case .pasteRelease: askForRelease()
        }
    }

    /// From Library Selection for `tracks`. `asked` is false for the one opening the window
    /// offers, which shows nothing unless the tracks hold an album to queue, and gives way to
    /// any sheet begun while the albums are read.
    private func queueFromSelection(_ tracks: [Int64], asked: Bool) {
        guard let session else { return }
        let database = session.setup.databaseURL
        let begun = sheetsBegun
        Task {
            let found = await blockingFileWork {
                Result { try LibraryIndex(at: database).discogsAlbums() }
            }
            let albums: [DiscogsAlbum]
            do {
                albums = try found.get()
            } catch {
                return alert("The library couldn't be read", ["\(error)"])
            }
            let choices = QueueChoice.selection(tracks, albums: albums)
            if !asked {
                guard choices.contains(where: { $0.refusal == nil }), sheetsBegun == begun,
                    controller?.window?.attachedSheet == nil
                else { return }
            }
            chooseAndQueue(
                heading: "From Library Selection",
                note: "The albums of the selected tracks, each downloaded as its release.",
                choices, upgrade: false, tickingAll: true)
        }
    }

    /// Not Found's button.
    static let queueAgainTitle = "Queue Again"

    /// Not Found's note, saying when Queue Again queues nothing until the box is on.
    static func notFoundNote(autoUpgrade: Bool) -> String {
        let box = AppSettings().autoUpgrade.title
        let note =
            "Albums \(box) set aside after searching four times. \(queueAgainTitle) clears"
            + " their misses"
        return autoUpgrade
            ? note + ", so it queues them in turn."
            : note + "; with \(box) off, nothing is queued until it's turned on."
    }

    /// Runs `change` on the index off the main thread, then `then`; an alert headed `failure`
    /// when it threw.
    private func write(
        _ failure: String, _ change: @escaping @Sendable (LibraryIndex) throws -> Void,
        then: @escaping () -> Void = {}
    ) {
        guard let database = session?.setup.databaseURL else { return }
        Task {
            let done = await blockingFileWork { Result { try change(LibraryIndex(at: database)) } }
            do {
                try done.get()
                then()
            } catch {
                alert(failure, ["\(error)"])
            }
        }
    }

    private func chooseAndQueue(
        heading: String, note: String, _ choices: [QueueChoice], upgrade: Bool,
        tickingAll: Bool, other: String? = nil, marked: @escaping ([QueueChoice]) -> Void = { _ in }
    ) {
        guard !choices.isEmpty else {
            return alert(
                "Nothing to queue",
                [upgrade ? "No library album can be upgraded." : "The selection holds no album."])
        }
        let queueSheet = QueueSheet(
            heading: heading, note: note, choices: choices,
            policies: FormatPolicy.offered(upgrade: upgrade), tickingAll: tickingAll,
            other: other)
        present(queueSheet) {
            if let chosen = queueSheet.marked { return marked(chosen) }
            guard let chosen = queueSheet.result else { return }
            self.queue(chosen.choices, chosen.policy)
        }
    }

    private func askForRelease() {
        guard let window = controller?.window else { return }
        let field = NSTextField(string: "")
        field.placeholderString = "1234567 or https://www.discogs.com/release/1234567"
        field.frame = NSRect(x: 0, y: 30, width: 340, height: 24)
        let policies = FormatPolicy.offered(upgrade: false)
        let popUp = formatPopUp(policies)
        popUp.frame = NSRect(x: 0, y: 0, width: 200, height: 26)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 56))
        accessory.addSubview(field)
        accessory.addSubview(popUp)
        let question = NSAlert()
        question.messageText = "Paste a Discogs release"
        question.informativeText =
            "Its id or its page's address. It must be in this Mac's Discogs catalog."
        question.accessoryView = accessory
        question.addButton(withTitle: QueueSheet.queueTitle)
        question.addButton(withTitle: "Cancel")
        question.window.initialFirstResponder = field
        question.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            guard let id = pastedReleaseID(field.stringValue) else {
                self.alert(
                    "That isn't a Discogs release",
                    ["\(field.stringValue.debugDescription) has no release id."])
                return
            }
            self.queue(
                [
                    QueueChoice(
                        title: DownloadRow.releaseName(id), detail: "", releaseID: id, upgrade: nil,
                        refusal: nil)
                ],
                policies[popUp.indexOfSelectedItem])
        }
    }

    /// Builds each choice's snapshot from the catalog and queues them, saying which failed.
    private func queue(_ choices: [QueueChoice], _ policy: FormatPolicy) {
        guard let session else { return }
        let catalog = session.setup.catalog
        Task {
            var orders: [(snapshot: ReleaseSnapshot, order: JobOrder)] = []
            var problems: [String] = []
            for choice in choices {
                guard let release = choice.releaseID, let order = choice.order(policy) else {
                    problems.append(
                        "\(choice.title): can't be queued as \(DownloadRow.policyName(policy))")
                    continue
                }
                let built = await blockingFileWork {
                    Result { try ReleaseSnapshot.queueable(releaseID: release, catalogAt: catalog) }
                }
                switch built {
                case .success(let snapshot): orders.append((snapshot, order))
                case .failure(let error): problems.append("\(choice.title): \(error)")
                }
            }
            problems += await session.model.create(orders)
            if !problems.isEmpty {
                alert(
                    "\(problems.count) of \(choices.count) weren't queued", problems)
            }
        }
    }

    // MARK: - Sheets and alerts

    /// Shows `controller`'s window as a sheet over the window, calling `ended` once it closes.
    /// Shows `controller` as a sheet of the window; false when it can't, because the window
    /// isn't up or a sheet is.
    @discardableResult
    private func present(_ controller: NSWindowController, ended: @escaping () -> Void) -> Bool {
        guard let window = self.controller?.window, let sheetWindow = controller.window,
            sheet == nil
        else { return false }
        sheet = controller
        refresh()
        window.beginSheet(sheetWindow) { _ in
            self.sheet = nil
            ended()
            self.refresh()
        }
        return true
    }

    private func confirm(
        _ message: String, _ detail: String, _ button: String, then: @escaping () -> Void
    ) {
        guard let window = controller?.window else { return }
        let question = NSAlert()
        question.messageText = message
        question.informativeText = detail
        question.addButton(withTitle: button)
        question.addButton(withTitle: "Don't")
        question.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { then() }
        }
    }

    private func alert(_ message: String, _ details: [String]) {
        guard let window = controller?.window else { return }
        let shown = 8
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText =
            details.prefix(shown).joined(separator: "\n")
            + (details.count > shown ? "\n(\(details.count - shown) more not shown)" : "")
        alert.beginSheetModal(for: window)
    }
}
