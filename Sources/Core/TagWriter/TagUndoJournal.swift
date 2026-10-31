import Foundation

/// The last edits' old bytes, so each can be undone byte for byte. One entry per edit, however
/// many files it changed, kept as a JSON file in `tag-undo` under the app's data directory, or
/// under `--home`'s folder and the tests' temp folders.
public struct TagUndoJournal: Sendable {
    /// Edits kept; an older one is dropped when a new one is saved.
    public static let capacity = 50
    static let folderName = "tag-undo"
    /// Entry files are the sequence number, zero-padded so they sort by name, then this.
    private static let sequenceDigits = 8
    private static let entrySuffix = ".json"

    public let directory: URL

    public init(dataDirectory: URL) {
        directory = dataDirectory.appendingPathComponent(Self.folderName)
    }

    /// One edit: every file it changed, with what restores each.
    struct Entry: Codable, Equatable {
        var sequence: Int
        var editedSeconds: Double
        var files: [FileRecord]
    }

    struct FileRecord: Codable, Equatable {
        var path: String
        /// The edited file's size and mtime. Undo refuses a file that no longer matches.
        var editedSize: Int
        var editedModifiedNanoseconds: Int
        /// The original's SHA-256, which the restored file must match.
        var originalSHA256: Data
        var restore: [RestoreSegment]
    }

    /// How the original is put back together: its old tag bytes, and ranges of the edited file.
    enum RestoreSegment: Codable, Equatable {
        case bytes(Data)
        case edited(lowerBound: Int, upperBound: Int)

        var segment: Segment {
            switch self {
            case .bytes(let data): .bytes(Array(data))
            case .edited(let lower, let upper): .original(lower..<upper)
            }
        }
    }

    /// The newest entry, or nil when there's none. An entry file that doesn't decode exactly is
    /// deleted and reported, and the one before it is tried, since stored data has one shape
    /// (AGENTS.md).
    func latest() throws(TagWriteError) -> (entry: Entry?, discarded: [TagWriteError]) {
        var discarded: [TagWriteError] = []
        for sequence in try sequences().reversed() {
            let url = fileURL(sequence)
            do {
                let entry = try decodeExactly(Entry.self, from: Data(contentsOf: url))
                guard entry.sequence == sequence else {
                    throw DecodingError.dataCorrupted(
                        .init(codingPath: [], debugDescription: "its sequence isn't its name"))
                }
                return (entry, discarded)
            } catch {
                discarded.append(
                    journalError("discarded \(url.path), which doesn't decode: \(error)"))
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    throw journalError("can't remove \(url.path): \(error)")
                }
            }
        }
        return (nil, discarded)
    }

    /// A new, empty entry after the newest one.
    func newEntry(at seconds: Double) throws(TagWriteError) -> Entry {
        Entry(sequence: (try sequences().last ?? 0) + 1, editedSeconds: seconds, files: [])
    }

    /// Saves `entry`, replacing an earlier save of it, and drops entries past `capacity`. An
    /// entry with no files is removed instead.
    func save(_ entry: Entry) throws(TagWriteError) {
        let url = fileURL(entry.sequence)
        do {
            guard !entry.files.isEmpty else {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return
            }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try encoder().encode(entry).write(to: url, options: .atomic)
        } catch {
            throw journalError("can't save \(url.path): \(error)")
        }
        for old in try sequences().dropLast(Self.capacity) {
            do {
                try FileManager.default.removeItem(at: fileURL(old))
            } catch {
                throw journalError("can't drop the old entry \(old): \(error)")
            }
        }
    }

    /// The entries' sequence numbers, from their file names, oldest first. Files that aren't
    /// entries are left alone.
    private func sequences() throws(TagWriteError) -> [Int] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .compactMap { name in
                    guard name.hasSuffix(Self.entrySuffix),
                        name.count == Self.sequenceDigits + Self.entrySuffix.count
                    else { return nil }
                    return Int(name.dropLast(Self.entrySuffix.count))
                }
                .sorted()
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            throw journalError("can't list \(directory.path): \(error)")
        }
    }

    private func fileURL(_ sequence: Int) -> URL {
        let digits = String(sequence)
        return directory.appendingPathComponent(
            String(repeating: "0", count: max(0, Self.sequenceDigits - digits.count)) + digits
                + Self.entrySuffix)
    }

    private func journalError(_ detail: String) -> TagWriteError {
        TagWriteError(path: directory.path, kind: .journal, detail: detail)
    }
}

private func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

/// Decodes `T` and fails unless encoding it again gives the same JSON, so an unknown or
/// misspelled key anywhere in the file is an error rather than ignored.
func decodeExactly<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
    let value = try JSONDecoder().decode(type, from: data)
    let read = try JSONSerialization.jsonObject(with: data) as? NSObject
    let written = try JSONSerialization.jsonObject(with: encoder().encode(value)) as? NSObject
    guard let read, let written, read.isEqual(written) else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "it holds keys or values \(type) doesn't"))
    }
    return value
}
