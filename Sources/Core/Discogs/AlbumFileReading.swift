import Foundation
import Metadata

/// Reads the tags of `files`, an album's or a match set's, as the change set compares them,
/// `filesReadAtOnce` at a time; blocks on the reads, so call it off the main thread. A file
/// that can't be read is a problem, by its path, and isn't in the files; `isStopped` ends the
/// reads before the next file.
public func readAlbumFiles(
    _ files: [(id: Int64, path: String)], isStopped: @escaping @Sendable () -> Bool = { false },
    read: @escaping @Sendable (Int) -> Void = { _ in }
) -> (files: [AlbumFile], problems: [String]) {
    let results = AlbumFileResults(count: files.count)
    DispatchQueue.concurrentPerform(iterations: min(filesReadAtOnce, files.count)) { _ in
        while !isStopped(), let index = results.claim() {
            let file = files[index]
            let url = URL(fileURLWithPath: file.path, isDirectory: false)
            do throws(MetadataError) {
                let parsed = try readMetadata(at: url)
                results.store(
                    .success(AlbumFile(id: file.id, path: file.path, metadata: parsed.metadata)),
                    at: index)
            } catch {
                results.store(.failure(ReadProblem(text: error.description)), at: index)
            }
            let done = results.done
            if isReported(done, of: files.count) { read(done) }
        }
    }
    var read: [AlbumFile] = []
    var problems: [String] = []
    for result in results.all {
        switch result {
        case .success(let file): read.append(file)
        case .failure(let problem): problems.append(problem.text)
        case nil: break
        }
    }
    return (read, problems)
}

/// A problem reading one file, as text.
private struct ReadProblem: Error {
    var text: String
}

/// The files `readAlbumFiles` has handed out, and what each read returned.
private final class AlbumFileResults: @unchecked Sendable {
    // Every field is guarded by `lock`.
    private let lock = NSLock()
    private var claimed = 0
    private var finished = 0
    private var results: [Result<AlbumFile, ReadProblem>?]

    init(count: Int) { results = Array(repeating: nil, count: count) }

    func claim() -> Int? {
        lock.withLock {
            guard claimed < results.count else { return nil }
            claimed += 1
            return claimed - 1
        }
    }

    func store(_ result: Result<AlbumFile, ReadProblem>, at index: Int) {
        lock.withLock {
            results[index] = result
            finished += 1
        }
    }

    var done: Int { lock.withLock { finished } }
    var all: [Result<AlbumFile, ReadProblem>?] { lock.withLock { results } }
}
