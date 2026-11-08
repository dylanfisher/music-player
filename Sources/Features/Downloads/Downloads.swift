import AppKit
import Discogs
import Foundation
import Library
import Log
import Metadata
import Recommender
import Settings

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
        /// `moveToTrash`, giving its failure.
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

        init(_ setup: Setup, model: DownloadsModel) {
            self.setup = setup
            self.model = model
        }
    }

    /// What the window says while the service isn't set.
    static let notSet =
        "music-recommender isn't set up on this Mac. Set its address and token in Settings >"
        + " General to list its downloads."

    private(set) var session: Session?
    private(set) var controller: DownloadsWindow?
    /// An open sheet's controller, held while it shows.
    private var sheet: NSWindowController?

    /// The selected library tracks' ids, for From Library Selection.
    package var selectedTracks: () throws -> [Int64] = { [] }
    /// Opens the Discogs tagger on a staged job, with the staging folder's path; the tagger's
    /// Apply reports its verdict through the closure.
    package var openInTagger:
        (StagedJob, String, @escaping @Sendable (AutoTagRun.Verdict) -> Void) -> Void = {
            _, _, _ in
        }

    package init() {}

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
                    guard self.session === session else { return }
                    session.problems = problems
                    self.refresh()
                }
            }
            model.start()
            if controller?.window?.isVisible == true { model.setWindowOpen(true) }
            refresh()
        }
        refresh()
    }

    /// Stops polling, at quit or when the service's settings are cleared.
    package func stop() {
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
            importRun: { job in
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
                    rescan: setup.rescan
                ).run(job)
            })
    }

    // MARK: - The window

    /// Shows the window, making it the first time.
    package func show() {
        let controller = self.controller ?? makeWindow()
        if self.controller == nil {
            self.controller = controller
            controller.window?.center()
        }
        refresh()
        controller.showWindow(nil)
        session?.model.setWindowOpen(true)
    }

    func makeWindow() -> DownloadsWindow {
        let made = DownloadsWindow()
        made.applies = { [weak self] action, row in self?.applies(action, row) ?? false }
        made.act = { [weak self] action, row in self?.act(action, row) }
        made.add = { [weak self] addition in self?.add(addition) }
        made.visibilityChanged = { [weak self] open in self?.session?.model.setWindowOpen(open) }
        controller = made
        return made
    }

    private func refresh() {
        guard let controller else { return }
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
        guard let session, sheet == nil, let job = session.model.job(row.id) else { return false }
        return DownloadAction.applies(
            action, to: job, machine: session.setup.machine,
            answering: session.model.connection == .answering, canTag: session.canTag)
    }

    // MARK: - Actions

    private func act(_ action: DownloadAction, _ row: DownloadRow) {
        guard let session, let job = session.model.job(row.id) else { return }
        switch action {
        case .approve: review(job, session, resuming: false)
        case .resumeHere: review(job, session, resuming: true)
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
        case .openInTagger:
            guard let coordinator = session.coordinator else { return }
            Task {
                guard let staged = await coordinator.stagedJob(job) else { return }
                let root: String
                do {
                    root = try await session.setup.places().stagingRoot
                } catch {
                    return alert("The staging folder wasn't found", ["\(error)"])
                }
                openInTagger(staged, root) { verdict in
                    Task {
                        let problem = await coordinator.resolved(
                            job, verdict, stagingRoot: root)
                        await MainActor.run {
                            if let problem { self.alert("The tagging wasn't reported", [problem]) }
                        }
                        await session.model.poll()
                    }
                }
            }
        }
    }

    /// Approve… and Resume Here: takes the review claim (Resume Here takes it over when it
    /// runs), works out the plan, and runs the import once the sheet approves it. Cancel gives
    /// a claim Approve took back.
    private func review(_ job: DownloadJob, _ session: Session, resuming: Bool) {
        guard let coordinator = session.coordinator else { return }
        let setup = session.setup
        Task {
            var job = job
            if !resuming {
                do throws(RecommenderError) {
                    job = try await coordinator.claimReview(job.id)
                } catch {
                    return alert("Another Mac may be reviewing this album", [error.description])
                }
                session.model.took(job)
                guard DownloadRow(job, machine: setup.machine)?.canApprove == true else {
                    return alert(
                        "This album can't be approved now",
                        ["It's \(job.state.rawValue), tagged \(job.tagging.status.rawValue)."])
                }
            }
            let places: ImportPlaces
            do {
                places = try await setup.places()
            } catch {
                return alert("The staging or library folder wasn't found", ["\(error)"])
            }
            let plan = await ApprovalPlan.build(
                job, places: places, databaseURL: setup.databaseURL,
                catalog: session.canTag ? setup.catalog : nil)
            let approve = ApproveSheet(plan: plan, album: DownloadRow.album(job.release))
            present(approve) {
                guard let approved = approve.result else {
                    guard !resuming else { return }
                    Task {
                        do throws(RecommenderError) {
                            session.model.took(try await coordinator.releaseReview(job.id))
                        } catch {
                            logger.info("job \(job.id)'s review claim not given up: \(error)")
                        }
                    }
                    return
                }
                Task {
                    let outcome =
                        resuming
                        ? await coordinator.resumeHere(approved)
                        : await coordinator.approve(approved)
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
        }
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
                    Result {
                        try LibraryIndex(at: setup.databaseURL).upgradeCandidates(onShare: share)
                    }
                }
                let candidates: [UpgradeCandidate]
                do {
                    candidates = try found.get()
                } catch {
                    return alert("The library couldn't be read", ["\(error)"])
                }
                chooseAndQueue(
                    heading: "Upgrades",
                    note:
                        "Lossy albums whose every track carries one Discogs release id. A lossless"
                        + " copy replaces each; Approve deletes the old files.",
                    QueueChoice.upgrades(candidates), upgrade: true, tickingAll: false)
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
            Task {
                let found = await blockingFileWork {
                    Result { try LibraryIndex(at: setup.databaseURL).discogsAlbums() }
                }
                let albums: [DiscogsAlbum]
                do {
                    albums = try found.get()
                } catch {
                    return alert("The library couldn't be read", ["\(error)"])
                }
                chooseAndQueue(
                    heading: "From Library Selection",
                    note: "The albums of the selected tracks, each downloaded as its release.",
                    QueueChoice.selection(selected, albums: albums), upgrade: false,
                    tickingAll: true)
            }
        case .pasteRelease: askForRelease()
        }
    }

    private func chooseAndQueue(
        heading: String, note: String, _ choices: [QueueChoice], upgrade: Bool,
        tickingAll: Bool
    ) {
        guard !choices.isEmpty else {
            return alert(
                "Nothing to queue",
                [upgrade ? "No library album can be upgraded." : "The selection holds no album."])
        }
        let queueSheet = QueueSheet(
            heading: heading, note: note, choices: choices,
            policies: FormatPolicy.offered(upgrade: upgrade), tickingAll: tickingAll)
        present(queueSheet) {
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
            guard let id = QueueChoice.pastedReleaseID(field.stringValue) else {
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
    private func present(_ controller: NSWindowController, ended: @escaping () -> Void) {
        guard let window = self.controller?.window, let sheetWindow = controller.window,
            sheet == nil
        else { return }
        sheet = controller
        refresh()
        window.beginSheet(sheetWindow) { _ in
            self.sheet = nil
            ended()
            self.refresh()
        }
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
