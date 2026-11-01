import Foundation
import Library
import Metadata
import SQLite
import Settings
import TagWriter

/// One thing the fuzzer feeds inputs to (ADR 0027).
struct FuzzTarget: Sendable {
    let name: String
    /// What it runs each input through.
    let summary: String
    /// The formats of the generated and tag-corpus files that seed it, by content.
    let seedFormats: Set<FileFormat>
    /// Byte strings the mutator inserts beside the IDs and keys it finds in the seeds.
    let tokens: [String]
    /// The inputs a seed file gives; the file's bytes unless the target reads part of a file.
    var seedInputs: @Sendable ([UInt8]) -> [[UInt8]] = { [$0] }
    /// Seeds the target makes itself in its work folder, from the generated library, for the
    /// targets no file seeds.
    var madeSeeds: @MainActor @Sendable (_ work: URL, _ library: URL) throws -> [[UInt8]] = {
        _, _ in []
    }
    /// Sets up in a work folder and returns the function that runs one input. That returns
    /// whether the input was accepted; one that's refused is fine. A broken invariant is a
    /// `preconditionFailure`, which the fuzzer catches as a crash.
    let prepare: @MainActor @Sendable (URL) throws -> ([UInt8]) -> Bool

    static let all: [FuzzTarget] = [
        parser(.flac, "FLAC metadata blocks and Vorbis comments"),
        parser(.mp4, "MP4 atoms, ilst items and the AAC config"),
        parser(.mp3, "ID3v1 and ID3v2 tags and MPEG audio frames"),
        parser(.wav, "RIFF chunks, INFO lists and ID3 chunks"),
        parser(.aiff, "AIFF and AIFF-C chunks and ID3 chunks"),
        vorbis, config, state, journal, rules, tagWriter,
    ]

    static func named(_ name: String) -> FuzzTarget? { all.first { $0.name == name } }
}

/// Values at JSON's edges, and comments, which the config file allows.
private let jsonTokens = ["-1", "1e999", "0.5", "\\u0000", "\\ud800", "//", "/*", "*/", "null"]

/// The one file a target writes each input to, in its work folder.
private let inputFileName = "fuzz-input"

/// A parser by content: the bytes go through the same `ByteReader` as a file on disk.
private func parser(_ format: FileFormat, _ summary: String) -> FuzzTarget {
    FuzzTarget(
        name: format.rawValue, summary: summary, seedFormats: [format], tokens: [],
        prepare: { _ in
            { input in
                do throws(ParseFailure) {
                    _ = try parse(ByteReader(MemorySource(input)))
                    return true
                } catch {
                    return false
                }
            }
        })
}

private let vorbis = FuzzTarget(
    name: "vorbis", summary: "a Vorbis comment block on its own", seedFormats: [.flac],
    tokens: [], seedInputs: vorbisBlocks,
    prepare: { _ in
        { input in
            do throws(ParseFailure) {
                let reader = ByteReader(MemorySource(input))
                _ = try parseVorbisComment(try reader.bytes(0..<input.count), reader)
                return true
            } catch {
                return false
            }
        }
    })

/// The VORBIS_COMMENT blocks of a FLAC file, found by walking its block headers.
func vorbisBlocks(_ file: [UInt8]) -> [[UInt8]] {
    let vorbisCommentType: UInt8 = 4
    guard file.starts(with: Array(flacMarker.utf8)) else { return [] }
    var blocks: [[UInt8]] = []
    var cursor = 4
    while cursor + 4 <= file.count {
        let header = file[cursor]
        let length =
            Int(file[cursor + 1]) << 16 | Int(file[cursor + 2]) << 8 | Int(file[cursor + 3])
        let body = cursor + 4..<min(cursor + 4 + length, file.count)
        if header & 0x7F == vorbisCommentType { blocks.append(Array(file[body])) }
        guard header & 0x80 == 0 else { break }
        cursor = body.upperBound
    }
    return blocks
}

private let config = FuzzTarget(
    name: "config-file", summary: "the config file, then a setting changed and the file read again",
    seedFormats: [], tokens: jsonTokens,
    madeSeeds: { work, _ in
        let url = work.appendingPathComponent(inputFileName)
        _ = ConfigStore(AppSettings(), fileURL: url, check: acceptShortcut, creating: true)
        let defaults = try [UInt8](Data(contentsOf: url))
        let store = ConfigStore(AppSettings(), fileURL: url, check: acceptShortcut, creating: false)
        try store.set(\.hogMode, to: false)
        try store.set(\.digitalVolume, to: true)
        return [defaults, try [UInt8](Data(contentsOf: url))]
    },
    prepare: { work in
        let url = work.appendingPathComponent(inputFileName)
        return { input in
            write(input, to: url)
            let store = ConfigStore(
                AppSettings(), fileURL: url, check: acceptShortcut, creating: false)
            guard store.problems.isEmpty else { return false }
            let hogMode = !store[\.hogMode]
            do {
                try store.set(\.hogMode, to: hogMode)
            } catch {
                return false
            }
            let reread = ConfigStore(
                AppSettings(), fileURL: url, check: acceptShortcut, creating: false)
            precondition(
                reread.problems.isEmpty && reread[\.hogMode] == hogMode,
                "a good config file doesn't read back after a change: \(reread.problems)")
            return true
        }
    })

private let acceptShortcut: ShortcutCheck = { _, _, _ in nil }

private let state = FuzzTarget(
    name: "state-file", summary: "the state file, then a value saved and the file read again",
    seedFormats: [], tokens: jsonTokens,
    madeSeeds: { work, _ in
        let url = work.appendingPathComponent(inputFileName)
        let store = try StateStore(AppState(), fileURL: url)
        try store.set(\.sidebarWidth, to: 200)
        try store.set(\.source, to: .playlist(3))
        try store.set(\.selectedGenre, to: "Seed Genre")
        try store.set(\.queueVisible, to: true)
        return [Array("{}".utf8), try [UInt8](Data(contentsOf: url))]
    },
    prepare: { work in
        let url = work.appendingPathComponent(inputFileName)
        return { input in
            write(input, to: url)
            let store: StateStore<AppState>
            do {
                store = try StateStore(AppState(), fileURL: url)
            } catch {
                return false
            }
            guard store.discardReason == nil else { return false }
            let width = store[\.sidebarWidth] == 200 ? 201 : 200
            do {
                try store.set(\.sidebarWidth, to: width)
                let reread = try StateStore(AppState(), fileURL: url)
                precondition(
                    reread.discardReason == nil && reread[\.sidebarWidth] == width,
                    "a good state file doesn't read back after a save: \(reread.discardReason ?? "")"
                )
            } catch {
                preconditionFailure("a good state file can't be saved and read: \(error)")
            }
            return true
        }
    })

private let journal = FuzzTarget(
    name: "undo-journal",
    summary: "an undo record (the first two bytes are its bytes file's size), read back",
    seedFormats: [], tokens: jsonTokens,
    madeSeeds: { work, library in
        // Real records, from editing copies of a few generated files.
        let data = work.appendingPathComponent("seed-data")
        let writer = TagWriter(journal: TagUndoJournal(dataDirectory: data))
        var seeds: [[UInt8]] = []
        let files = audioFiles(in: library)
        for file in stride(from: 0, to: files.count, by: max(1, files.count / 10)).map({ files[$0] }
        ) {
            let copy = work.appendingPathComponent("seed-" + file.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: file, to: copy)
            _ = writer.write(TagEdit(values: [.title: "Seed"]), to: [copy.path])
        }
        for record in try journalRecords(in: data) {
            let bytes = bytesFile(of: record)
            let size = try FileManager.default.attributesOfItem(atPath: bytes.path)[.size] as! Int
            seeds.append(
                [UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)] + (try Data(contentsOf: record)))
        }
        return seeds
    },
    prepare: { work in
        let data = work.appendingPathComponent("app-data")
        let undo = TagUndoJournal(dataDirectory: data)
        // One record written by the journal itself, to learn the names it reads.
        try? FileManager.default.removeItem(at: data)
        let entry = try undo.newEntry()
        _ = try undo.append(
            .init(
                path: "/nonexistent", editedSize: 0, editedModifiedNanoseconds: 0, editedInode: 0,
                originalSHA256: Data(), restore: []),
            oldBytes: [], to: entry)
        guard let record = try journalRecords(in: data).first else {
            throw FuzzError("the journal wrote no record in \(data.path)")
        }
        let bytes = bytesFile(of: record)
        return { input in
            guard input.count >= 2 else { return false }
            let size = Int(input[0]) << 8 | Int(input[1])
            do {
                try FileManager.default.createDirectory(
                    at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                preconditionFailure("can't make \(record.path): \(error)")
            }
            write(Array(input[2...]), to: record)
            write([UInt8](repeating: 0, count: size), to: bytes)
            do throws(TagWriteError) {
                return try undo.latest().entry != nil
            } catch {
                return false
            }
        }
    })

/// The undo records under a data folder, in order.
private func journalRecords(in data: URL) throws -> [URL] {
    let enumerator = FileManager.default.enumerator(at: data, includingPropertiesForKeys: nil)
    return (enumerator?.allObjects as? [URL] ?? [])
        .filter { $0.lastPathComponent.hasSuffix(TagUndoJournal.recordSuffix) }
        .sorted { $0.path < $1.path }
}

private func bytesFile(of record: URL) -> URL {
    URL(
        fileURLWithPath: record.path.dropLast(TagUndoJournal.recordSuffix.count)
            + TagUndoJournal.bytesSuffix)
}

private let rules = FuzzTarget(
    name: "smart-rules", summary: "smart-playlist rules as stored, decoded and listed",
    seedFormats: [], tokens: jsonTokens + SmartOrder.allCases.map { "\"\($0.rawValue)\"" },
    madeSeeds: { _, _ in
        let examples = [
            SmartRules(match: .all, rules: []),
            SmartRules(
                match: .any,
                rules: [
                    SmartRule(.artist, .contains, .text("Delay")),
                    SmartRule(.title, .startsWith, .text("%_\\")),
                ], limit: SmartLimit(count: 25, order: .mostPlayed)),
        ]
        return try examples.map { Array(try $0.json().utf8) }
            + SmartField.allCases.flatMap { field in
                try SmartComparison.comparisons(for: field.kind).map { comparison in
                    let value: SmartValue = field.kind == .text ? .text("a") : .number(3)
                    let rules = SmartRules(
                        match: .all, rules: [SmartRule(field, comparison, value)])
                    return Array(try rules.json().utf8)
                }
            }
    },
    prepare: { work in
        let url = work.appendingPathComponent(inputFileName)
        let index = try LibraryIndex(at: url)
        let id = try index.createPlaylist(named: "Fuzz", rules: SmartRules(match: .all, rules: []))
        let store = try SQLite.Database(at: url).prepare(
            "UPDATE playlists SET rules = ? WHERE id = ?")
        return { input in
            let json = String(decoding: input, as: UTF8.self)
            let decoded = try? SmartRules(json: json)
            if let decoded {
                let again: SmartRules
                do {
                    again = try SmartRules(json: try decoded.json())
                } catch {
                    preconditionFailure("decoded rules don't encode and decode: \(error)")
                }
                precondition(again == decoded, "rules don't survive their own JSON: \(json)")
            }
            do {
                try store.run(json, id)
                _ = try index.trackIDs(TrackFilter(source: .playlist(id)), sortedBy: .title)
            } catch {
                let valid =
                    decoded.map {
                        $0.rules.allSatisfy { $0.problem == nil } && $0.limit?.problem == nil
                    }
                    ?? false
                precondition(!valid, "valid rules fail to list: \(error)\n\(json)")
                return false
            }
            return decoded != nil
        }
    })

private let tagWriter = FuzzTarget(
    name: "tag-writer", summary: "a tag edit written to the input as a file, then undone",
    seedFormats: [.flac, .mp4, .mp3, .wav, .aiff], tokens: [],
    prepare: { work in
        let file = work.appendingPathComponent(inputFileName)
        let data = work.appendingPathComponent("app-data")
        let writer = TagWriter(journal: TagUndoJournal(dataDirectory: data))
        let edits = [
            TagEdit(values: [.title: "Fuzz Title", .artist: "Fuzz Artist", .trackNumber: "7"]),
            TagEdit(values: [
                .album: "", .compilation: "1", .comment: String(repeating: "x", count: 300),
            ]),
        ]
        return { input in
            try? FileManager.default.removeItem(at: data)
            write(input, to: file)
            let written = writer.write(edits[input.count % edits.count], to: [file.path])
            guard written.changed == [file.path] else { return false }
            let undone = writer.undoLast()
            precondition(
                undone.changed == [file.path] && undone.failures.isEmpty,
                "an edit that was written didn't undo: \(undone)")
            let restored: [UInt8]
            do {
                restored = try [UInt8](Data(contentsOf: file))
            } catch {
                preconditionFailure("can't read \(file.path) after the undo: \(error)")
            }
            precondition(restored == input, "undo didn't restore the bytes")
            return true
        }
    })

/// Writes an input in place; a failure here is the fuzzer's own and stops it.
private func write(_ bytes: [UInt8], to url: URL) {
    do {
        try Data(bytes).write(to: url)
    } catch {
        preconditionFailure("can't write \(url.path): \(error)")
    }
}

struct FuzzError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
