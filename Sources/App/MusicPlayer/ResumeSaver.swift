import Foundation
import Log
import Settings

private let logger = moduleLogger()

/// Writes the play state to the config file (ADR 0092), which syncs, so it changes a few times
/// an hour at most: a track starting, a pause or a source change asks for a write, which runs
/// `delaySeconds` later and at least `intervalSeconds` after the last one, and reads the state
/// as it is then. Playing on asks for nothing. Quitting writes at once.
@MainActor
final class ResumeSaver {
    static let delaySeconds = 5.0
    static let intervalSeconds = 30.0

    private let settings: ConfigStore<AppSettings>
    /// Where playback and the window are now; nil when that couldn't be read.
    private let read: () async -> ResumePoint?
    private var scheduled = false
    private var lastWrite: Date?
    /// The clock and the scheduler; tests run them without waiting.
    var now: () -> Date = Date.init
    var runAfter: (Double, @escaping @MainActor () -> Void) -> Void = { seconds, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(work) }
    }

    init(_ settings: ConfigStore<AppSettings>, read: @escaping () async -> ResumePoint?) {
        self.settings = settings
        self.read = read
    }

    /// Something the play state keeps changed; a write follows, unless one is already due.
    func changed() {
        guard !scheduled else { return }
        scheduled = true
        let sinceLast = lastWrite.map { now().timeIntervalSince($0) } ?? .infinity
        let wait = max(Self.delaySeconds, Self.intervalSeconds - sinceLast)
        runAfter(wait) { [weak self] in
            Task { await self?.save() }
        }
    }

    /// Reads the play state and writes it, unless it's what the file has. A config that
    /// refuses changes (ADR 0082) is logged; the next change tries again.
    func save() async {
        scheduled = false
        guard let point = await read() else { return }
        lastWrite = now()
        guard point != settings[\.resume] else { return }
        do {
            try settings.set(\.resume, to: point)
        } catch {
            logger.error("couldn't save the play state: \(error)")
        }
    }
}
