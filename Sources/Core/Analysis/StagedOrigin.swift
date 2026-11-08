import Foundation

/// What the lossy-origin check found in one staged file (ADR 0139), for the Approve sheet. The
/// file is analyzed with `analyzeFile(at:)` and nothing else, so no staged path reaches the
/// index or the measures cache.
package struct StagedOrigin: Equatable, Sendable {
    package var path: String
    /// Its `lossyOrigin` and `upsampled` verdicts; empty when it shows neither.
    package var verdicts: [Verdict]
    /// Why it couldn't be analyzed, which the sheet asks about as it does a verdict.
    package var failure: String?

    /// Whether Approve waits for the owner to acknowledge this file.
    package var blocks: Bool { !verdicts.isEmpty || failure != nil }
}

/// The verdicts that say a staged file isn't the lossless copy it claims to be.
private let originKinds: Set<Verdict.Kind> = [.lossyOrigin, .upsampled]

/// How many of a staged album's files the check analyzes: decoding a whole file over the share
/// takes seconds, and one album's files come from one rip.
let stagedOriginFileCount = 2

/// Analyzes the first and last of `paths`, a staged album's files in order, on a task of its
/// own at utility priority: the reads block. Cancelling the caller stops the file being
/// analyzed.
package func stagedOrigins(_ paths: [String]) async throws -> [StagedOrigin] {
    let chosen =
        paths.count <= stagedOriginFileCount ? paths : [paths[0], paths[paths.count - 1]]
    return try await offMain { try origins(of: chosen) }
}

private func origins(of chosen: [String]) throws -> [StagedOrigin] {
    try chosen.map { path in
        do {
            let result = try analyzeFile(at: URL(fileURLWithPath: path, isDirectory: false))
            return StagedOrigin(
                path: path,
                verdicts: verdicts(result.measures).filter { originKinds.contains($0.kind) },
                failure: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return StagedOrigin(path: path, verdicts: [], failure: "\(error)")
        }
    }
}
