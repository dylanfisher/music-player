import AppKit

/// What the Trash took of the files it was given.
struct TrashOutcome: Sendable {
    var moved: Set<URL>
    /// Why the rest weren't moved, when any weren't.
    var failure: String?
}

/// Moves the files at `urls`, which the user confirmed in Remove…, to the Trash. The one call
/// besides `TagWriter` that moves a music file (ADR 0050); nothing else calls it.
///
/// A file moved is one gone from its path afterwards. The reply's URLs needn't equal the ones
/// given, and a share with no Trash deletes the file and still reports an error.
@MainActor
func moveToTrash(_ urls: [URL]) async -> TrashOutcome {
    let failure: String? = await withCheckedContinuation { continuation in
        NSWorkspace.shared.recycle(urls) { _, error in
            continuation.resume(returning: error.map { "\($0)" })
        }
    }
    let moved = await Task.detached {
        Set(urls.filter { !FileManager.default.fileExists(atPath: $0.path) })
    }.value
    return TrashOutcome(
        moved: moved,
        failure: moved.count == urls.count ? nil : failure ?? "the files are still there")
}
