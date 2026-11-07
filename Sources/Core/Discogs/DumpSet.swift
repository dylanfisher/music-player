import Foundation

/// One month's dumps in a folder: `discogs_<date>_<kind>.xml.gz` for each kind, and
/// `discogs_<date>_CHECKSUM.txt` with each file's SHA-256.
struct DumpSet: Equatable, Sendable {
    /// As the names have it: "20261101".
    var date: String
    var files: [DumpKind: URL]
    /// Each file's SHA-256 in lowercase hex, by kind.
    var checksums: [DumpKind: String]
    /// Every file's size, added up: what the import reads.
    var compressedBytes: Int

    /// The newest date in `folder` with all four dumps, a checksum file listing each of them,
    /// and nothing else of the set missing. A newer date with a file still downloading, or no
    /// checksum file, is passed over for an older complete one.
    static func newest(in folder: URL) throws(CatalogImportError) -> DumpSet {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            throw .unreadable(folder.path, error.localizedDescription)
        }
        let dates = Set(names.compactMap(date)).sorted(by: >)
        for date in dates {
            if let set = try complete(date, in: folder, names: Set(names)) { return set }
        }
        throw .noDumpSet(folder: folder.path, found: names.filter { date($0) != nil }.sorted())
    }

    /// The date in a dump set's file name, or nil for any other file.
    private static func date(_ name: String) -> String? {
        let parts = name.split(separator: "_")
        guard parts.count == 3, parts[0] == "discogs", parts[1].count == 8,
            parts[1].allSatisfy(\.isASCII), parts[1].allSatisfy(\.isNumber)
        else { return nil }
        return String(parts[1])
    }

    private static func fileName(_ date: String, _ kind: DumpKind) -> String {
        "discogs_\(date)_\(kind.rawValue).xml.gz"
    }

    private static func complete(_ date: String, in folder: URL, names: Set<String>)
        throws(CatalogImportError) -> DumpSet?
    {
        let checksumName = "discogs_\(date)_CHECKSUM.txt"
        guard names.contains(checksumName),
            DumpKind.allCases.allSatisfy({ names.contains(fileName(date, $0)) })
        else { return nil }
        let listed = try checksums(in: folder.appendingPathComponent(checksumName))
        var checksums: [DumpKind: String] = [:]
        var files: [DumpKind: URL] = [:]
        var bytes = 0
        for kind in DumpKind.allCases {
            let name = fileName(date, kind)
            guard let checksum = listed[name] else { return nil }
            let url = folder.appendingPathComponent(name, isDirectory: false)
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard let size else { throw CocoaError(.fileReadUnknown) }
                bytes += size
            } catch {
                throw .unreadable(name, error.localizedDescription)
            }
            checksums[kind] = checksum
            files[kind] = url
        }
        return DumpSet(date: date, files: files, checksums: checksums, compressedBytes: bytes)
    }

    /// The checksum file's lines, `<sha256> <file name>`, by file name.
    static func checksums(in url: URL) throws(CatalogImportError) -> [String: String] {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw .unreadable(url.lastPathComponent, error.localizedDescription)
        }
        var checksums: [String: String] = [:]
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            // `sha256sum` writes two spaces, or a space and `*` for a binary file.
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            let hash = parts[0].lowercased()
            guard parts.count == 2, hash.count == 64, hash.allSatisfy(\.isHexDigit) else {
                throw .badChecksumFile(url.lastPathComponent, line: index + 1)
            }
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            checksums[name] = hash
        }
        return checksums
    }
}
