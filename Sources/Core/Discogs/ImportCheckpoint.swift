import CommonCrypto
import Foundation
import SQLite

/// Where an unfinished import carries on from (ADR 0134). It's the one row of
/// `import_checkpoint` in `<catalog>.importing`, written in the transaction that commits the
/// rows it covers, so it always matches them. Stored as JSON with its SHA-256 beside it: a
/// checkpoint that doesn't match its hash is damaged, and the import starts over.
struct ImportCheckpoint: Codable, Equatable, Sendable {
    /// The dump set's date and each file's checksum in import order: a set of the same date
    /// downloaded again isn't resumed.
    var dumpDate: String
    var checksums: [String]
    /// The tables it was written with, `CatalogSchema.identity`.
    var schema: String
    /// The set's compressed bytes.
    var totalBytes: Int
    /// The files read to their end and checked, in `DumpKind` order, and their compressed
    /// bytes added up.
    var filesFinished: Int
    var finishedBytes: Int
    /// The records committed, by kind.
    var records: [String: Int]
    /// In the file after the finished ones: the record to start at, and the access point
    /// before it. Nil at the file's start.
    var position: Position?
    /// Whether the indexes are built and the catalog is complete: all that's left is the swap.
    var indexed: Bool

    struct Position: Codable, Equatable, Sendable {
        var record: DumpPosition
        var accessPoint: GzipAccessPoint
    }

    /// A checkpoint at the start of an import of `set`.
    init(starting set: DumpSet) {
        dumpDate = set.date
        checksums = DumpKind.allCases.map { set.checksums[$0] ?? "" }
        schema = CatalogSchema.identity
        totalBytes = set.compressedBytes
        filesFinished = 0
        finishedBytes = 0
        records = [:]
        position = nil
        indexed = false
    }

    /// Whether it's from an import of `set`, by this build.
    func belongs(to set: DumpSet) -> Bool {
        dumpDate == set.date && checksums == DumpKind.allCases.map { set.checksums[$0] ?? "" }
            && schema == CatalogSchema.identity && totalBytes == set.compressedBytes
    }

    /// The compressed bytes a resume skips.
    var bytesRead: Int { finishedBytes + (position?.accessPoint.compressedOffset ?? 0) }

    /// The file the import is in, nil once every file is finished.
    var kind: DumpKind? {
        filesFinished < DumpKind.allCases.count ? DumpKind.allCases[filesFinished] : nil
    }

    func count(_ kind: DumpKind) -> Int { records[kind.rawValue] ?? 0 }

    /// Replaces the checkpoint in `database`, inside the caller's transaction.
    func write(to database: Database) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(self), as: UTF8.self)
        try database.execute("DELETE FROM import_checkpoint")
        try database.prepare("INSERT INTO import_checkpoint (checkpoint, sha256) VALUES (?, ?)")
            .run(json, sha256(json))
    }

    /// The checkpoint in `database`. Throws `Damaged` when there's none, or it doesn't match
    /// its hash, decode, or agree with itself.
    static func read(from database: Database) throws -> ImportCheckpoint {
        let rows = try database.prepare("SELECT checkpoint, sha256 FROM import_checkpoint").map {
            (json: try $0.text(0), hash: try $0.text(1))
        }
        guard rows.count == 1, sha256(rows[0].json) == rows[0].hash else { throw Damaged() }
        let checkpoint: ImportCheckpoint
        do {
            checkpoint = try JSONDecoder().decode(
                ImportCheckpoint.self, from: Data(rows[0].json.utf8))
        } catch {
            throw Damaged()
        }
        guard checkpoint.isConsistent else { throw Damaged() }
        return checkpoint
    }

    /// Whether its numbers can be resumed from: a file being read, and the record after the
    /// access point. A checkpoint as written always is.
    private var isConsistent: Bool {
        guard (0...DumpKind.allCases.count).contains(filesFinished), finishedBytes >= 0,
            finishedBytes <= totalBytes, records.values.allSatisfy({ $0 >= 0 })
        else { return false }
        guard let position else { return true }
        return kind != nil && position.record.line >= 1
            && position.record.offset >= position.accessPoint.inflatedOffset
    }

    /// A checkpoint that's missing, or isn't what was written.
    struct Damaged: Error {}
}

/// `text`'s SHA-256, in lowercase hex.
private func sha256(_ text: String) -> String {
    let bytes = Array(text.utf8)
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CC_SHA256(bytes, CC_LONG(bytes.count), &digest)
    return digest.map { String(format: "%02x", $0) }.joined()
}
