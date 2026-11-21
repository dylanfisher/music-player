import AppKit
import Commands
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
    /// What a pasted id offers, read from the catalog at a place off the main thread.
    var readDiscographyArtists: @Sendable (PastedDiscogsID, URL?) async -> DiscographyChoice = {
        pasted, url in
        await Task.detached { DiscographyChoice.of(pasted, DiscographyArtists(catalogAt: url)) }
            .value
    }
    /// This Mac's Discogs catalog as set now, which the Marked sheet names marks from; a mark
    /// whose album it doesn't have, or every mark while there is none, goes by its id.
    package var catalog: () -> URL? = { nil }
    /// Download…: queues the albums in Downloads' queue sheet.
    package var download: ([RecommendationPage.Album]) -> Void = { _ in }
    /// music-recommender's status page as set now; nil while its address isn't set.
    package var statusPage: () -> URL? = { nil }
    /// Opens a Discogs page or the status page; tests record it instead.
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
    /// The track menus whose Show Discography item is filled as they open.
    private var discographyMenus: [TrackMenuDiscography] = []
    /// This Mac's catalog's reads for Show Discography, as set now; tests stand in for it.
    lazy var discographyArtists: () -> DiscographyArtists = { [unowned self] in
        DiscographyArtists(catalogAt: catalog())
    }
    /// The track menu's Show Discography items, which hold it as their target.
    private lazy var discographyItems: DiscographyItems = {
        let items = DiscographyItems()
        items.open = { [weak self] in self?.showDiscography($0) }
        return items
    }()

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

    // MARK: - Discographies

    /// Gives `menu` a Show Discography item, after a separator unless it has one already,
    /// filled each time the menu opens for the track whose Discogs release `release` reads,
    /// through its main artists in this Mac's catalog. Both are point reads by primary key, so
    /// they run as the menu opens (ADR 0217). The menu holds its delegate weakly, so this
    /// does; the menu needs no other delegate.
    public func showDiscography(in menu: NSMenu, release: @escaping () throws -> Int?) {
        if menu.item(withTitle: AppMenus.showDiscographyMenuTitle) == nil {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(
                withTitle: AppMenus.showDiscographyMenuTitle, action: nil, keyEquivalent: "")
        }
        let delegate = TrackMenuDiscography()
        delegate.fill = { [weak self] in self?.fillDiscographyItem($0, release: release) }
        menu.delegate = delegate
        discographyMenus.append(delegate)
    }

    /// A Show Discography item for a row of another window, such as a Downloads job, through
    /// `release`'s main artists in this Mac's catalog.
    package func discographyItem(release: Int?) -> NSMenuItem {
        let item = NSMenuItem(
            title: AppMenus.showDiscographyMenuTitle, action: nil, keyEquivalent: "")
        fillDiscographyItem(item) { release }
        return item
    }

    private func fillDiscographyItem(_ item: NSMenuItem, release: () throws -> Int?) {
        let choice: DiscographyChoice
        do {
            choice = DiscographyChoice.of(release: try release(), discographyArtists().release)
        } catch {
            choice = .unavailable(terminalSafe("Couldn't read the track's release: \(error)"))
        }
        discographyItems.fill(item, choice)
    }

    /// Shows `artist`'s discography, in the order and through the filters the window has.
    func showDiscography(_ artist: RecommendationPage.Named) {
        let known = model.seeds.first {
            if case .discography(artist.id, _) = $0 { true } else { false }
        }
        var query = model.query
        query.seed = known ?? .discography(artistID: artist.id, name: artistName(artist))
        (controller ?? makeWindow()).showWindow(nil)
        model.show(query)
    }

    /// Show Discography…: asks for a Discogs artist, release or master, pasted or typed, and
    /// shows its discography.
    public func askForDiscography() {
        let controller = controller ?? makeWindow()
        controller.showWindow(nil)
        guard let window = controller.window, window.attachedSheet == nil else { return }
        let field = NSTextField(string: "")
        field.placeholderString = "https://www.discogs.com/artist/1234567"
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        let question = NSAlert()
        question.messageText = "Paste a Discogs artist, release or master"
        question.informativeText =
            "Its page's address, or a release's id. A release or master shows its main"
            + " artist's discography."
        question.accessoryView = field
        question.addButton(withTitle: AppMenus.showDiscographyMenuTitle)
        question.addButton(withTitle: "Cancel")
        question.window.initialFirstResponder = field
        question.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.showDiscography(pasted: field.stringValue)
        }
    }

    /// Shows the discography of what was pasted, after choosing among a release's artists
    /// when it has several, or says why there is none.
    @discardableResult
    func showDiscography(pasted text: String) -> Task<Void, Never>? {
        guard let pasted = pastedDiscogsID(text) else {
            beep()
            model.tell("That isn't a Discogs artist, release or master: \(terminalSafe(text))")
            return nil
        }
        let artists = readDiscographyArtists
        let catalog = catalog()
        return Task {
            let choice = await artists(pasted, catalog)
            switch choice {
            case .unavailable(let why):
                beep()
                model.tell(why)
            case .artists(let artists) where artists.count == 1: showDiscography(artists[0])
            case .artists(let artists): chooseDiscography(artists)
            }
        }
    }

    /// Asks which of several artists' discography to show.
    private func chooseDiscography(_ artists: [RecommendationPage.Named]) {
        guard let window = controller?.window, window.attachedSheet == nil else { return }
        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        popUp.addItems(withTitles: artists.map(artistName))
        let question = NSAlert()
        question.messageText = "Whose discography?"
        question.accessoryView = popUp
        question.addButton(withTitle: AppMenus.showDiscographyMenuTitle)
        question.addButton(withTitle: "Cancel")
        question.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.showDiscography(artists[popUp.indexOfSelectedItem])
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
        made.statusChosen = { [weak self] in self?.openStatusPage() }
        made.downloadChosen = { [weak self] in self?.download($0.map(\.album)) }
        made.discogsChosen = { [weak self] in self?.open(discogsPage(of: $0.album)) }
        made.discographyChosen = { [weak self] in self?.showDiscography($0) }
        made.askDiscography = { [weak self] in self?.askForDiscography() }
        made.columnsResized = { [weak self] widths in
            self?.columnWidths = widths
            self?.columnWidthsChanged(widths)
        }
        made.visibilityChanged = { [weak self] open in
            if open { self?.model.resume() } else { self?.model.stop() }
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

    /// Service Status: opens music-recommender's status page in the browser, or beeps and says
    /// what to set while its address isn't set.
    func openStatusPage() {
        guard let page = statusPage() else {
            beep()
            return say(serviceAddressNotSetText)
        }
        open(page)
    }

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
        if let pending = model.pending, pending > 0 { message = fetchingText(pending) }
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
        } else if !model.isReading, !model.more, model.rows.isEmpty {
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
