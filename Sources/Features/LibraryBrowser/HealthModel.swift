import Library

/// Runs the library health report on request and when a scan ends, never on a timer, and keeps
/// the newest. Each run takes a session number; a run that a newer one started after finishes
/// building late is dropped, so an old report never replaces a newer one. `report` is always
/// the one the table lists.
@MainActor
final class HealthModel {
    private(set) var report: HealthReport?
    /// Whether a run is going, so showing a check before the first report starts only one.
    private(set) var isRunning = false
    /// Called once a run's report is shown.
    var changed: () -> Void = {}
    var failed: (String) -> Void = { _ in }

    private let build: @MainActor () async throws -> HealthReport
    private let show: @MainActor (HealthReport) async throws -> Void
    private var session = 0

    /// `build` makes a report off the main thread; `show` hands it to the connection whose
    /// `.health` sources list it.
    init(
        build: @escaping @MainActor () async throws -> HealthReport,
        show: @escaping @MainActor (HealthReport) async throws -> Void
    ) {
        self.build = build
        self.show = show
    }

    func run() async {
        session += 1
        let mine = session
        isRunning = true
        do {
            let report = try await build()
            guard mine == session else { return }
            try await show(report)
            // The table lists it now, so `report` follows even when a newer run has started:
            // that run replaces both, or, if it fails, leaves the two agreeing.
            self.report = report
            if mine == session { isRunning = false }
            changed()
        } catch {
            guard mine == session else { return }
            isRunning = false
            failed("couldn't check the library's health: \(error)")
        }
    }
}
