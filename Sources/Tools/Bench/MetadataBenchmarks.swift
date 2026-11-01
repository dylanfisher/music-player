import Fixtures
import Foundation
import Metadata

/// Reads the fixture library at its default location, which this process hasn't read, so the
/// first pass is as cold as an unprivileged process can make it: the files may still be in the
/// page cache from earlier runs, since evicting them needs `sudo purge` (ADR 0007).
let metadataBenchmarks = [
    Benchmark(
        name: "metadata: parse \(fullLibraryFileCount) fixture files, first read in this process",
        budget: Budget(appleSilicon: 5, oldMac: 20, unit: .seconds)
    ) {
        let root = try defaultFixturesDirectory()
        let generation = try generateFixtures(count: fullLibraryFileCount, in: root)
        let files = try loadManifest(in: root).files
        let first = try parseAll(files, in: root)
        let second = try parseAll(files, in: root)
        var notes = [
            first.summary(files.count),
            first.readsPerFile(),
            String(
                format: "second pass: %.2f s, %.0f files/s", second.seconds,
                Double(files.count) / second.seconds),
        ]
        if generation == .generated {
            notes.append("the library was written in this run, so the first pass read cached pages")
        }
        return Measured(value: first.seconds, notes: notes)
    }
]

private struct Pass {
    var seconds = 0.0
    var bytesRead = 0
    var readCount = 0
    var mostBytesRead = 0
    var parsed = 0
    /// Files by how many reads each took.
    var filesByReads: [Int: Int] = [:]

    func summary(_ fileCount: Int) -> String {
        String(
            format: "%.0f files/s, %.1f MB/s; per file %.0f bytes in %.2f reads, at most %d bytes",
            Double(fileCount) / seconds, Double(bytesRead) / seconds / 1e6,
            Double(bytesRead) / Double(parsed), Double(readCount) / Double(parsed), mostBytesRead)
    }

    /// "files by reads: 1 read 38000, 2 reads 4900, 3 reads 64".
    func readsPerFile() -> String {
        "files by reads: "
            + filesByReads.keys.sorted().map { reads in
                "\(reads) read\(reads == 1 ? "" : "s") \(filesByReads[reads]!)"
            }.joined(separator: ", ")
    }
}

/// Parses every file in order on one thread. Every file must parse except those broken in their
/// structure.
private func parseAll(_ files: [FixtureFile], in root: URL) throws -> Pass {
    var pass = Pass()
    pass.seconds = try seconds {
        for file in files {
            do throws(MetadataError) {
                // Without `isDirectory`, Foundation stats the path to find out, which took a
                // fifth of the pass and which the scanner, working on paths, never pays.
                let parsed = try readMetadata(
                    at: root.appendingPathComponent(file.path, isDirectory: false))
                pass.bytesRead += parsed.bytesRead
                pass.readCount += parsed.readCount
                pass.mostBytesRead = max(pass.mostBytesRead, parsed.bytesRead)
                pass.parsed += 1
                pass.filesByReads[parsed.readCount, default: 0] += 1
            } catch {
                if file.malformation?.isFieldLevel ?? true { throw error }
            }
        }
    }
    return pass
}
