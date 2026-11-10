import Foundation
import HALOutput

/// What the lossy-origin check found in one staged file (ADR 0147), for the Approve sheet. The
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

/// The ones of `files`, a staged album's in order, that the check analyzes: the first and the
/// last.
package func stagedOriginChoice<File>(_ files: [File]) -> [File] {
    files.count <= stagedOriginFileCount ? files : [files[0], files[files.count - 1]]
}

/// Analyzes the first and last of `paths`, a staged album's files in order, each on a task of
/// its own at utility priority, both at once: the reads block, and on the share each takes
/// seconds. Cancelling the caller stops the files being analyzed. `latency` slows each file's
/// reads, for the bench's simulated NAS.
package func stagedOrigins(_ paths: [String], latency: FileLatency? = nil) async throws
    -> [StagedOrigin]
{
    try await stagedOrigins(paths) { try analyzeFile(at: $0, latency: latency) }
}

/// `stagedOrigins(_:)` with `analyze` in place of `analyzeFile(at:)`, for the tests. The
/// results keep the order of `paths`, whichever file finishes first.
func stagedOrigins(
    _ paths: [String], analyze: @escaping @Sendable (URL) throws -> AnalysisResult
) async throws -> [StagedOrigin] {
    let chosen = stagedOriginChoice(paths)
    return try await withThrowingTaskGroup(of: (Int, StagedOrigin).self) { group in
        for (index, path) in chosen.enumerated() {
            group.addTask { (index, try await offMain { try origin(of: path, analyze) }) }
        }
        var origins = [StagedOrigin?](repeating: nil, count: chosen.count)
        for try await (index, origin) in group { origins[index] = origin }
        return origins.map { $0! }
    }
}

private func origin(
    of path: String, _ analyze: (URL) throws -> AnalysisResult
) throws -> StagedOrigin {
    do {
        let result = try analyze(URL(fileURLWithPath: path, isDirectory: false))
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
