import AppKit

/// What the Trash took of the files it was given.
public struct TrashOutcome: Sendable {
    public var moved: Set<URL>
    /// Why the rest weren't moved, when any weren't.
    public var failure: String?
}

/// Moves the files at `urls` to the Trash: those the user confirmed in Remove… (ADR 0050), and
/// those an approved upgrade replaces, which reach the import as a closure (ADR 0139). The one
/// call besides `TagWriter` and the import's rename that moves a music file.
///
/// A file moved is one gone from its path afterwards. The reply's URLs needn't equal the ones
/// given, and a share with no Trash deletes the file and still reports an error.
@MainActor
public func moveToTrash(_ urls: [URL]) async -> TrashOutcome {
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
