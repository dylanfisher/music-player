import Foundation
import Metadata

/// Removes the old files an approved import replaces (ADR 0199): each one in turn to its
/// volume's Trash with `trashItem`, `FileManager.trashItem` but for tests, and one on a volume
/// with no Trash, such as the NAS's share, deleted at once. Unlike `moveToTrash` it goes through
/// no Finder, so nothing asks before the delete; the Approve sheet, or the box that approves
/// unasked, was the confirmation. Each file not removed with why, nil when all were.
package func trashOrDelete(
    _ urls: [URL],
    trashItem: @escaping @Sendable (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }
) async -> String? {
    await blockingFileWork {
        let failures = urls.compactMap { url -> String? in
            do {
                do {
                    try trashItem(url)
                } catch CocoaError.featureUnsupported {
                    try FileManager.default.removeItem(at: url)
                }
                return nil
            } catch {
                return "\(url.path): \(error)"
            }
        }
        return failures.isEmpty ? nil : failures.joined(separator: "; ")
    }
}
