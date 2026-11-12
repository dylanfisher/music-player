import AppKit
import DisplayText
import Library
import Recommender

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
    /// The system beep; tests count it instead.
    var beep: () -> Void = { NSSound.beep() }
    private var sendingProfile = false

    /// `databaseURL` is the library index the profile is read from.
    public init(databaseURL: URL) {
        readProfile = {
            try await Task.detached { try LibraryIndex(at: databaseURL).libraryProfile() }.value
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
}
