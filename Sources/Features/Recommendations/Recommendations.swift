import AppKit
import DisplayText
import Library
import Recommender
import Settings
import WindowPlacement

/// music-recommender's lists of albums the library doesn't have (phase 86, ADR 0205), and
/// Send Library Profile to Service, which sends the profile only when asked.
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
    /// The system beep; tests count it instead.
    var beep: () -> Void = { NSSound.beep() }
    private var sendingProfile = false
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

    /// Send Library Profile to Service: reads the profile, sends it, and says what the service
    /// did with it, or why it couldn't. One send at a time.
    @discardableResult
    public func sendProfile() -> Task<Void, Never>? {
        guard !sendingProfile else {
            beep()
            say("The library profile is already being sent")
            return nil
        }
        guard let service = service() else { return nil }
        sendingProfile = true
        say("Sending the library profile…")
        return Task {
            defer { sendingProfile = false }
            do {
                let profile = try await readProfile()
                say(profileSentSummary(try await service.sendProfile(profile)))
            } catch {
                report(terminalSafe("couldn't send the library profile: \(error)"))
            }
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
        made.queryChosen = { [weak self] in self?.model.show($0) }
        made.reachedEnd = { [weak self] in self?.model.readMore() }
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
        controller.show(
            rows: model.rows, query: model.query, seeds: model.seeds,
            pending: model.isReading, message: message, action: action,
            facts: model.facts.map(factsText))
    }
}
