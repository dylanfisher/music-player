import AppKit
import Discogs
import DisplayText
import Library
import Recommender
import Settings
import WindowPlacement

/// music-recommender's lists of albums the library doesn't have (ADR 0205), and the
/// library profile, sent unasked when it changed and by Send Library Profile to Service
/// (ADR 0206).
@MainActor
public final class Recommendations {
    /// The calls to the service as set now; nil while its address or token isn't set.
    package var service: () -> RecommendationsService? = { nil }
    /// Shows a line in the main window's status bar.
    public var say: (String) -> Void = { _ in }
    /// Logs a failure and shows it in the status bar.
    public var report: (String) -> Void = { _ in }
    /// The profile Export Library Profile… writes, read off the main thread.
    var readProfile: @Sendable () async throws -> LibraryProfile
    /// The albums of some tracks, for a seed, read off the main thread.
    var readSeeds: @Sendable ([Int64]) async throws -> [SeedAlbum]
    /// This Mac's Discogs catalog as set now, which the Marked sheet names marks from; a mark
    /// whose album it doesn't have, or every mark while there is none, goes by its id.
    package var catalog: () -> URL? = { nil }
    /// Download…: queues the albums in Downloads' queue sheet.
    package var download: ([RecommendationPage.Album]) -> Void = { _ in }
    /// Opens a Discogs page; tests record it instead.
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// The system beep; tests count it instead.
    var beep: () -> Void = { NSSound.beep() }
    /// The state of each release's newest download job, by release id, from Downloads.
    private var downloads: [Int: String] = [:]
    private var sendingProfile = false
    /// Every send of the profile, asked or not, one at a time.
    private(set) lazy var profileSender = makeProfileSender()
    /// The window's column widths, as the state file keeps them.
    public var columnWidths = ColumnWidths()
    public var columnWidthsChanged: (ColumnWidths) -> Void = { _ in }
    private(set) lazy var model = RecommendationsModel(service: { [weak self] in
        self?.service()
    })
    private(set) var controller: RecommendationsWindow?

    /// `databaseURL` is the library index the profile is read from.
    public init(databaseURL: URL) {
        readProfile = {
            try await Task.detached { try LibraryIndex(at: databaseURL).libraryProfile() }.value
        }
        readSeeds = { ids in
            try await Task.detached {
                try LibraryIndex(at: databaseURL).recommendationSeeds(trackIDs: ids)
            }.value
        }
    }

    private func makeProfileSender() -> ProfileSender {
        ProfileSender(
            read: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await readProfile()
            },
            send: { [weak self] in
                guard let service = self?.service() else { return nil }
                let send: ProfileSender.Send = { profile throws(RecommenderError) in
                    try await service.sendProfile(profile)
                }
                return send
            })
    }

    /// Send Library Profile to Service: reads the profile, sends it though it may be the one
    /// sent last, and says what the service did with it, or why it couldn't.
    @discardableResult
    public func sendProfile() -> Task<Void, Never>? {
        guard !sendingProfile else {
            beep()
            say("The library profile is already being sent")
            return nil
        }
        guard service() != nil else { return nil }
        sendingProfile = true
        say("Sending the library profile…")
        let sending = profileSender.send(force: true)
        return Task {
            defer { sendingProfile = false }
            switch await sending.value {
            case .sent(let receipt): say(profileSentSummary(receipt))
            case .failed(let why): report(profileFailure(why))
            case .notSet, .unchanged: break
            }
        }
    }

    /// Sends the profile through the one sender, if it changed unless `force`, as Rediscover
    /// asks before it reads a day, answering how it went.
    package func sendProfile(force: Bool) async -> ProfileSender.Outcome {
        await profileSender.send(force: force).value
    }

    /// Sends the profile unasked, at launch and after a scan, if it changed since the last
    /// send. Only a failure is said.
    @discardableResult
    public func sendProfileIfChanged() -> Task<Void, Never> {
        let sending = profileSender.send()
        return Task {
            if case .failed(let why) = await sending.value { report(profileFailure(why)) }
        }
    }

    /// Recommendations for Album or for Artist: shows the list of the selected tracks' one
    /// album or one artist, or beeps and says why there is none.
    @discardableResult
    public func show(_ kind: SeedKind, forTracks ids: [Int64]) -> Task<Void, Never> {
        Task {
            let albums: [SeedAlbum]
            do {
                albums = try await readSeeds(ids)
            } catch {
                return report(terminalSafe("\(kind.commandTitle): \(error)"))
            }
            switch seed(kind, of: albums) {
            case .failure(let problem):
                beep()
                say(problem.text)
            case .success(let seed):
                var query = model.query
                query.seed = seed
                (controller ?? makeWindow()).showWindow(nil)
                model.show(query)
            }
        }
    }

    /// Shows the states of Downloads' jobs, by release id, in the Download column.
    package func show(downloads: [Int: String]) {
        self.downloads = downloads
        controller?.show(downloads: downloads)
    }

    // MARK: - The window

    /// File > Recommendations…: shows the window, making it the first time, where it was left,
    /// and reads its list unless it has one.
    public func show() {
        let controller = controller ?? makeWindow()
        controller.showWindow(nil)
        if model.rows.isEmpty, !model.isReading { model.show(model.query) }
    }

    private func makeWindow() -> RecommendationsWindow {
        let made = RecommendationsWindow()
        controller = made
        made.window?.keepsFrame(as: RecommendationsWindow.title)
        made.keepWidths(columnWidths)
        made.show(downloads: downloads)
        made.queryChosen = { [weak self] in self?.model.show($0) }
        made.reachedEnd = { [weak self] in self?.model.readMore() }
        made.markChosen = { [weak self] in self?.mark($0, $1) }
        made.showMarked = { [weak self] in self?.showMarked() }
        made.downloadChosen = { [weak self] in self?.download($0.map(\.album)) }
        made.discogsChosen = { [weak self] in self?.open(discogsPage(of: $0.album)) }
        made.columnsResized = { [weak self] widths in
            self?.columnWidths = widths
            self?.columnWidthsChanged(widths)
        }
        made.visibilityChanged = { [weak self] open in
            if !open { self?.model.stop() }
        }
        model.changed = { [weak self] in self?.redraw() }
        return made
    }

    /// Whether `window` is the Recommendations window, where Open Discogs Release opens the
    /// selected album's page.
    public func isOwnWindow(_ window: NSWindow?) -> Bool {
        window != nil && window === controller?.window
    }

    /// Whether the window has a row selected, for Open Discogs Release.
    public var hasSelection: Bool { controller?.selectedRows.isEmpty == false }

    /// Open Discogs Release while the window is key: the first selected album's page.
    public func openSelectedOnDiscogs() { controller?.discogsClicked() }

    // MARK: - Marks

    /// Not Interested or Already Have on `rows`, which Edit > Undo takes back.
    private func mark(_ rows: [RecommendationRow], _ verdict: FeedbackMark.Verdict) {
        guard let marking = model.mark(rows, verdict) else { return }
        Task {
            let marked = await marking.value
            guard !marked.isEmpty, let undo = controller?.window?.undoManager else { return }
            undo.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated { _ = target.model.unmark(marked) }
            }
            undo.setActionName(verdictTitle(verdict))
        }
    }

    /// Marked…: reads every mark, names each from the catalog, and shows them in a sheet.
    private func showMarked() {
        guard let service = service(), let window = controller?.window,
            window.attachedSheet == nil
        else { return }
        let catalog = catalog().flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
        Task {
            let named: [(mark: FeedbackMark, name: String)]
            do {
                let marks = try await service.marks()
                named = try await Task.detached {
                    let names = try catalog.map { try Catalog(at: $0) }
                    return try marks.map { mark in
                        let name = try names?.markName(mark.kind, mark.id)
                        return (mark, name ?? "\(mark.kind) \(mark.id)")
                    }
                }.value
            } catch {
                return report(terminalSafe("couldn't read the marks: \(error)"))
            }
            let sheet = MarkedSheet(named)
            let model = model
            sheet.removeChosen = { marks in
                model.unmark(marks.map { MarkedAlbum(kind: $0.kind, id: $0.id) })
            }
            sheet.done = { [weak sheet] in
                guard let sheetWindow = sheet?.window else { return }
                sheetWindow.sheetParent?.endSheet(sheetWindow)
            }
            guard let sheetWindow = sheet.window else { return }
            window.beginSheet(sheetWindow) { _ in _ = sheet }
        }
    }

    private func redraw() {
        guard let controller else { return }
        let model = model
        let seed = model.query.seed
        var message = model.isReading ? pendingText(seed) : nil
        var action: (title: String, run: () -> Void)?
        if let problem = model.problem {
            message = problemText(problem, seed: seed)
            switch problem {
            case .refused(let refusal) where refusal.code == .noProfile:
                action = ("Send Library Profile", { [weak self] in self?.sendProfile() })
            case .busy, .failed:
                action = ("Try Again", { [weak self] in self?.model.readAgain(through: 0) })
            default: break
            }
        } else if !model.isReading, model.rows.isEmpty {
            message = "The list has no albums these filters keep."
        }
        if let notice = model.notice {
            message = message.map { "\(notice)\n\($0)" } ?? notice
        }
        controller.show(
            rows: model.rows, query: model.query, seeds: model.seeds,
            pending: model.isReading, message: message, action: action,
            facts: model.facts.map(factsText))
    }
}

/// The Discogs page of `album`: its master's, or its release's when it has no master.
func discogsPage(of album: RecommendationPage.Album) -> URL {
    switch album.kind {
    case .master: discogsMasterPage(album.id)
    case .release: discogsPage(album.id)
    }
}
