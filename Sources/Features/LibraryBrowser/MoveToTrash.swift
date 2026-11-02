import AppKit

/// What the Trash took of the files it was given.
struct TrashOutcome: Sendable {
    var moved: Set<URL>
    /// Why the rest weren't moved, when any weren't.
    var failure: String?
}

/// Moves the files at `urls`, which the user confirmed in Remove…, to the Trash. The one call
/// besides `TagWriter` that moves a music file (ADR 0050); nothing else calls it.
@MainActor
func moveToTrash(_ urls: [URL]) async -> TrashOutcome {
    await withCheckedContinuation { continuation in
        NSWorkspace.shared.recycle(urls) { moved, error in
            continuation.resume(
                returning: TrashOutcome(moved: Set(moved.keys), failure: error.map { "\($0)" }))
        }
    }
}
