import Library

/// One import preview sheet's state: the library read, the plan shown, and the newest request
/// for another prefix. A plan is shown, and an import confirmed, only from the newest request
/// that succeeded, so a slow earlier preview can't replace a later one.
@MainActor
final class PlayerImportSession {
    private(set) var shown: ImportPlan
    /// Whether a preview is running, while the sheet's Import waits.
    private(set) var isPreviewing = false
    private var latest = 0
    private let plan: (PathPrefix?) async throws -> ImportPlan

    init(shown: ImportPlan, plan: @escaping (PathPrefix?) async throws -> ImportPlan) {
        self.shown = shown
        self.plan = plan
    }

    /// The plan for `prefix`, which is shown from now on; nil when a later request came while it
    /// ran, whose result wins instead. A failure leaves the plan shown before.
    func preview(_ prefix: PathPrefix?) async throws -> ImportPlan? {
        latest += 1
        let request = latest
        isPreviewing = true
        defer { if request == latest { isPreviewing = false } }
        let result = try await plan(prefix)
        guard request == latest else { return nil }
        shown = result
        return result
    }
}
