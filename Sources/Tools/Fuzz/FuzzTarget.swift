import Fixtures
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
        vorbis, config, state, journal, rules, playlistFile, syncLog, swinsian, swinsianPredicate,
        swinsianColumns, iTunesXML, tagWriter, receiverLine, deviceDescription, soapReply,
        avTransportReply, serviceDescription, httpRequest, didlLite, chunkedBody,
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
                originalSize: 0,
                originalModifiedNanoseconds: 0, originalInode: 0,
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
            + TagUndoJournal.bytesSuffix, isDirectory: false)
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

/// The folder relative playlist entries are read from, and written relative to.
private let playlistFolder = "/fuzz/Playlists"

private let playlistFile = FuzzTarget(
    name: "playlist-file",
    summary: "a playlist file (the first byte picks M3U, M3U8 or PLS), written back and read again",
    seedFormats: [],
    tokens: ["#EXTM3U", "#EXTINF:", "File1=", "file://", "%C3%A9", "../"],
    madeSeeds: { _, _ in
        let m3u8 =
            "#EXTM3U\r\n#EXTINF:200,A - T\r\n/Music/Café.flac\r\nB/c.flac\r\nfile:///d%20e.flac\n"
        let pls = "[playlist]\nFile2=/b.flac\nTitle2=B\nFile1=../a.flac\nNumberOfEntries=2\n"
        return [
            [1] + [0xEF, 0xBB, 0xBF] + Array(m3u8.utf8),
            [0] + Array("/Caf".utf8) + [0xE9, 0x0D] + Array("x/../y.mp3\rhttp://a/b".utf8),
            [2] + Array(pls.utf8),
        ]
    },
    prepare: { _ in
        { input in
            guard let selector = input.first else { return false }
            let formats = PlaylistFile.Format.allCases
            let format = formats[Int(selector) % formats.count]
            let file: PlaylistFile
            do throws(PlaylistFileError) {
                file = try PlaylistFile(
                    Array(input.dropFirst()), format: format, folder: playlistFolder)
            } catch {
                return false
            }
            precondition(
                file.problems.count <= PlaylistFile.maximumProblems, "problems past the cap")
            for path in file.paths {
                precondition(
                    path.hasPrefix("/") && !path.unicodeScalars.contains("\0")
                        && !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
                        || path == "/",
                    "an entry isn't a folded absolute path: \(path.debugDescription)")
            }
            let tracks = file.paths.map {
                PlaylistFileTrack(path: $0, durationSeconds: 1, artist: nil, title: "t")
            }
            for folder in [nil, playlistFolder] {
                let (bytes, unwritable) = m3u8Bytes(tracks, relativeTo: folder)
                let again: PlaylistFile
                do throws(PlaylistFileError) {
                    again = try PlaylistFile(bytes, format: .m3u8, folder: playlistFolder)
                } catch {
                    preconditionFailure("a written playlist doesn't read: \(error)")
                }
                let skipped = Set(unwritable)
                let expected = file.paths.filter { !skipped.contains($0) }
                    .map(\.precomposedStringWithCanonicalMapping)
                precondition(
                    again.paths == expected && again.problems.isEmpty,
                    "entries don't survive being written: \(expected) became \(again.paths)")
            }
            return file.problems.isEmpty && !file.paths.isEmpty
        }
    })

/// The keys of a sync log line that hold one path, and the one that holds a list of them.
private let syncPathKeys = ["path", "from", "to"]
private let syncPathListKey = "paths"

private let syncLog = FuzzTarget(
    name: "sync-log",
    summary:
        "another machine's sync log, read line by line, each event written back and read again,"
        + " then merged whole into a library",
    seedFormats: [],
    tokens: [
        #""seq":"#, #""event":"#, #""playlistEntries""#, #""paths":["#, "\\ud83c\\udfb5", "e301",
        "..",
    ],
    madeSeeds: { _, _ in
        let id = String(repeating: "0f", count: 16)
        let lines = [
            #"{"seq":1,"ms":1800000000000,"n":0,"event":"play","path":"music/tracks/a.flac","at":1700000000.5}"#,
            #"{"seq":2,"ms":1800000000001,"n":3,"event":"move","from":"music/tracks/a.flac","to":"music/tracks/Cafe\u0301.flac"}"#,
            #"{"seq":3,"ms":1800000000002,"n":0,"event":"playlistCreate","playlist":"\#(id)","name":"Mix","rules":null}"#,
            #"{"seq":4,"ms":1800000000003,"n":0,"event":"playlistEntries","playlist":"\#(id)","paths":["music/tracks/a.flac","music/tracks/b"]}"#,
            #"{"seq":5,"ms":1800000000004,"n":0,"event":"counts","path":"music/tracks/a.flac","player":"swinsian","plays":2,"skips":0,"lastPlayed":null}"#,
        ]
        return [Array((lines.joined(separator: "\n") + "\n").utf8), Array(lines[0].utf8)]
    },
    prepare: { work in
        // Then the whole input is merged as a log into a library, a new one every 500 inputs.
        let sync = work.appendingPathComponent("logs")
        let libraryFolder = work.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        func freshLibrary() throws -> LibraryIndex {
            if FileManager.default.fileExists(atPath: libraryFolder.path) {
                try FileManager.default.removeItem(at: libraryFolder)
            }
            let index = try LibraryIndex(at: libraryFileURL(in: libraryFolder))
            let share = "smb://fuzz/music"
            _ = try index.locate(
                [WatchedFolder(path: "tracks", share: share, kind: .network)],
                among: [MountedShare(url: share, mountPoint: work.path + "/share")])
            return index
        }
        var library = try freshLibrary()
        var runs = 0
        var log: URL?
        return { input in
            runs += 1
            if runs % 500 == 0 { library = try! freshLibrary() }
            // A new machine each time, so the log is read from its start.
            if let log { try! FileManager.default.removeItem(at: log) }
            let next = sync.appendingPathComponent(syncLogName(String(format: "%032x", runs)))
            try! Data(input).write(to: next)
            log = next
            let report: SyncReport
            do {
                report = try library.sync(folder: sync.lastPathComponent, at: sync.path)
            } catch {
                preconditionFailure("a log stopped the whole sync: \(error)")
            }
            precondition(
                report.problems.count <= SyncReport.maximumProblems + 2, "problems past the cap")
            var reader = SyncLogLines(from: 0, end: input.count, maximumLine: 1 << 16) {
                Array(input[$0])
            }
            var accepted = 0
            while let line = try! reader.next() {
                guard case .line(let bytes) = line,
                    let record = try? SyncRecord(line: bytes[...])
                else { continue }
                let written = record.line
                precondition(!written.utf8.contains(0x0A), "a written line holds a line break")
                guard let again = try? SyncRecord(line: Array(written.utf8)[...]), again == record
                else { preconditionFailure("an event doesn't survive being written: \(written)") }
                // Foundation, apart from the log's own parser, must read the same paths.
                guard
                    let object = try? JSONSerialization.jsonObject(with: Data(written.utf8))
                        as? [String: Any]
                else { preconditionFailure("Foundation can't read \(written)") }
                let paths =
                    syncPathKeys.compactMap { object[$0] as? String }
                    + (object[syncPathListKey] as? [String] ?? [])
                for path in paths {
                    precondition(
                        !path.isEmpty && !path.hasPrefix("/") && !path.unicodeScalars.contains("\0")
                            && path == path.precomposedStringWithCanonicalMapping
                            && !path.split(separator: "/", omittingEmptySubsequences: false)
                                .contains { $0.isEmpty || $0 == "." || $0 == ".." },
                        "a path isn't relative, folded and in NFC: \(path.debugDescription)")
                }
                accepted += 1
            }
            precondition(
                reader.offset == 0 || input[reader.offset - 1] == 0x0A,
                "reading stopped mid-line, at \(reader.offset)")
            return accepted > 0
        }
    })

private let swinsian = FuzzTarget(
    name: "swinsian", summary: "a Swinsian library database, copied aside and read",
    seedFormats: [],
    tokens: ["CREATE TABLE", "smartpredicate", "playlisttrack", "playcount", "favourite"],
    madeSeeds: { work, _ in
        let url = work.appendingPathComponent("seed.sqlite")
        try? FileManager.default.removeItem(at: url)
        let database = try Database(at: url)
        // Swinsian's schema, with values of every type the reader checks for.
        try database.execute("PRAGMA journal_mode = DELETE;" + swinsianSchemaSQL)
        let rules = try swinsianPredicateShapes.prefix(2).map {
            "X'" + (try swinsianPredicateArchive($0)).map { String(format: "%02X", $0) }.joined()
                + "'"
        }
        try database.execute(
            """
            INSERT INTO track (track_id, path, playcount, lastplayed, dateadded, rating, favourite)
            VALUES (1, '/Music/Café.flac', 3, 700000000.5, 600000000, 4.5, 1),
                (2, '/Music/Cafe\u{301}.flac', 'x', 0, -5, 9, 2);
            INSERT INTO playlist (playlist_id, name, smart, smartpredicate)
            VALUES (1, 'Mix', 0, NULL), (2, 'New', 1, \(rules[0])), (3, 'Week', 1, \(rules[1]));
            INSERT INTO playlisttrack (playlist_id, track_id, tindex) VALUES (1, 2, 1), (1, 1, 2), (1, 7, 3);
            """)
        return [try [UInt8](Data(contentsOf: url))]
    },
    prepare: { work in
        let url = work.appendingPathComponent(inputFileName)
        return { input in
            write(input, to: url)
            let library: PlayerLibrary
            do {
                library = try PlayerLibrary.read(.swinsian, at: url)
            } catch {
                return false
            }
            checkPlayerLibrary(library)
            return !library.tracks.isEmpty
        }
    })

private let swinsianPredicate = FuzzTarget(
    name: "swinsian-predicate", summary: "a Swinsian smart playlist's archived predicate",
    seedFormats: [],
    tokens: ["CF$UID"],
    madeSeeds: { _, _ in try swinsianPredicateShapes.map(swinsianPredicateArchive) },
    prepare: { _ in
        { input in
            switch SwinsianPredicate.kind(input) {
            case .smart(let rules):
                precondition(
                    rules.rules.allSatisfy { $0.problem == nil },
                    "a mapped rule is invalid: \(rules)")
                return true
            case .unmapped(let reasons):
                precondition(
                    !reasons.isEmpty && reasons.count <= SwinsianPredicate.maximumReasons + 1,
                    "\(reasons.count) reasons")
                return false
            case .manual, .smartAsManual: preconditionFailure("an archive made a manual playlist")
            }
        }
    })

private let swinsianColumns = FuzzTarget(
    name: "swinsian-columns", summary: "Swinsian's preferences, for its track table's columns",
    seedFormats: [], tokens: ["CF$UID", "bplist00"],
    // Swinsian names the first two columns as we do; we have no column for the third.
    madeSeeds: { _, _ in
        let columns = [
            (TrackColumn.title.rawValue, 397.0), (TrackColumn.artist.rawValue, 362),
            ("currentlyPlaying", 64),
        ]
        return [
            [UInt8](
                try swinsianPreferences(
                    columns: columns, sort: (TrackColumn.artist.rawValue, true)))
        ]
    },
    prepare: { work in
        let url = work.appendingPathComponent(inputFileName)
        return { input in
            write(input, to: url)
            let columns: SwinsianColumns
            do {
                columns = try SwinsianColumns(preferencesAt: url)
            } catch {
                return false
            }
            let layout = columns.layout(
                over: TrackTableLayout(
                    columns: [ColumnLayout(column: .title, width: 100)], sortColumn: .artist,
                    sortAscending: true))
            precondition(layout.problem() == nil, "an invalid layout: \(layout)")
            return true
        }
    })

private let iTunesXML = FuzzTarget(
    name: "itunes-xml", summary: "an iTunes or Music Library.xml",
    seedFormats: [], tokens: ["<key>", "<integer>", "<date>", "<true/>", "file://", "%C3%A9"],
    madeSeeds: { _, _ in
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>Tracks</key><dict>
            <key>1</key><dict><key>Track ID</key><integer>1</integer>
            <key>Location</key><string>file:///Music/Caf%C3%A9.m4a</string>
            <key>Play Count</key><integer>3</integer><key>Skip Count</key><integer>1</integer>
            <key>Play Date UTC</key><date>2020-01-02T03:04:05Z</date>
            <key>Date Added</key><date>2019-01-02T03:04:05Z</date>
            <key>Rating</key><integer>80</integer><key>Loved</key><true/></dict>
            <key>2</key><dict><key>Track ID</key><integer>2</integer>
            <key>Location</key><string>file://localhost/Music/b.mp3</string>
            <key>Rating</key><integer>100</integer><key>Rating Computed</key><true/></dict>
            </dict>
            <key>Playlists</key><array>
            <dict><key>Name</key><string>Library</string><key>Master</key><true/></dict>
            <dict><key>Name</key><string>Mix</string><key>Playlist Items</key><array>
            <dict><key>Track ID</key><integer>2</integer></dict>
            <dict><key>Track ID</key><integer>1</integer></dict></array></dict>
            <dict><key>Name</key><string>Smart</string><key>Smart Info</key><data>AQ==</data>
            <key>Playlist Items</key><array><dict><key>Track ID</key><integer>1</integer></dict>
            </array></dict>
            </array></dict></plist>
            """
        return [Array(xml.utf8)]
    },
    prepare: { work in
        let url = work.appendingPathComponent(inputFileName)
        return { input in
            write(input, to: url)
            let library: PlayerLibrary
            do {
                library = try PlayerLibrary.read(.iTunes, at: url)
            } catch {
                return false
            }
            checkPlayerLibrary(library)
            return !library.tracks.isEmpty
        }
    })

/// What every library read must hold, whatever the file: capped problems, one track per path
/// in NFC, absolute NUL-free paths, ratings in stars, dates from 1970, and playlists naming
/// only tracks read.
private func checkPlayerLibrary(_ library: PlayerLibrary) {
    precondition(
        library.problems.count <= PlaylistFile.maximumProblems, "problems past the cap")
    let keys = library.tracks.map(\.path.precomposedStringWithCanonicalMapping)
    precondition(Set(keys).count == keys.count, "two tracks for one path: \(keys)")
    for track in library.tracks {
        precondition(
            track.path.hasPrefix("/") && !track.path.unicodeScalars.contains("\0"),
            "a track's path isn't absolute and NUL-free: \(track.path.debugDescription)")
        precondition(
            track.rating.map { (1...5).contains($0) } ?? true, "a rating of \(track.rating!)")
        for date in [track.lastPlayedSeconds, track.addedSeconds].compactMap({ $0 }) {
            precondition(date >= 0 && date.isFinite, "a date of \(date)")
        }
    }
    let paths = Set(library.tracks.map(\.path))
    for playlist in library.playlists {
        precondition(
            playlist.paths.allSatisfy(paths.contains), "a playlist names a track not read")
        if case .smart(let rules) = playlist.kind {
            precondition(
                rules.rules.allSatisfy { $0.problem == nil }, "a mapped rule is invalid: \(rules)")
        }
    }
}

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
