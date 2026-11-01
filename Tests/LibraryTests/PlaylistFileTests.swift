import Foundation
import Testing

@testable import Library

private let folder = "/Users/owner/Playlists"

private func read(_ text: String, _ format: PlaylistFile.Format = .m3u8) throws -> PlaylistFile {
    try PlaylistFile(Array(text.utf8), format: format, folder: folder)
}

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("playlist-files-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func readsAbsoluteRelativeAndFileURLEntries() throws {
    let file = try read(
        """
        #EXTM3U
        #EXTINF:200,Artist - Title
        /Volumes/music/a.flac
        Albums/b.flac
        ../Music/./c.flac
        file:///Volumes/music/d%20e%C3%A9.flac
        file://localhost/f.flac
        FILE:/g.flac
        Live: 1999/h.flac

        """)
    #expect(
        file.paths == [
            "/Volumes/music/a.flac", folder + "/Albums/b.flac", "/Users/owner/Music/c.flac",
            "/Volumes/music/d eé.flac", "/f.flac", "/g.flac", folder + "/Live: 1999/h.flac",
        ])
    #expect(file.problems.isEmpty)
}

@Test func aBOMCRLFAndLoneCRAreLineEndsNotText() throws {
    let bytes = [0xEF, 0xBB, 0xBF] + Array("#EXTM3U\r\n/a.flac\r\n/b.flac\r/c.flac".utf8)
    let file = try PlaylistFile(bytes, format: .m3u, folder: folder)
    #expect(file.paths == ["/a.flac", "/b.flac", "/c.flac"])
    #expect(file.problems.isEmpty)
    // Only the first BOM is a mark; one starting a later line is part of its name.
    #expect(try read("/a.flac\n\u{FEFF}b.flac").paths == ["/a.flac", folder + "/\u{FEFF}b.flac"])
}

@Test func legacyM3UIsUTF8WhenValidElseWindows1252() throws {
    let utf8 = try PlaylistFile(Array("/Café.flac".utf8), format: .m3u, folder: folder)
    #expect(utf8.paths == ["/Café.flac"])
    // 0xE9 is é in Latin-1 and Windows-1252; 0x80 is the euro sign only in Windows-1252.
    let legacy = try PlaylistFile(
        Array("/Caf".utf8) + [0xE9, 0x20, 0x80] + Array(".mp3".utf8),
        format: .m3u, folder: folder)
    #expect(legacy.paths == ["/Café €.mp3"])
    // M3U8 is UTF-8 only: the bad line is reported and the next one still read.
    let m3u8 = try PlaylistFile(
        Array("/Caf".utf8) + [0xE9] + Array("\n/ok.flac".utf8), format: .m3u8, folder: folder)
    #expect(m3u8.paths == ["/ok.flac"])
    #expect(m3u8.problems == [PlaylistFileProblem(line: 1, .invalidText)])
}

@Test func plsEntriesAreReadInTheirNumberedOrder() throws {
    let file = try read(
        """
        [playlist]
        File2=/b.flac
        Title2=B
        Length2=100
        File1=c/a.flac
        ; a comment
        NumberOfEntries=2
        Version=2
        Bogus=1
        """, .pls)
    #expect(file.paths == [folder + "/c/a.flac", "/b.flac"])
    #expect(file.problems == [PlaylistFileProblem(line: 9, .unknownLine)])
}

@Test func hostileEntriesAreSkippedAndReportedWithTheirLine() throws {
    let long = "/" + String(repeating: "x", count: PlaylistFile.maximumLineBytes)
    let file = try read(
        """
        http://example.invalid/a.mp3
        smb://nas/music/b.flac
        C:\\Music\\c.mp3
        file://nas/d.flac
        file:///bad%zz.flac
        file:///nul%00.flac
        /nul\u{0}.flac
        \(long)
        /ok.flac
        """)
    #expect(file.paths == ["/ok.flac"])
    #expect(
        file.problems.map(\.kind) == [
            .scheme("http"), .scheme("smb"), .windowsPath, .badFileURL, .badFileURL, .badFileURL,
            .invalidText, .lineTooLong,
        ])
    #expect(file.problems.map(\.line) == Array(1...8))
    // `..` past the root stays at the root, without asking the disk.
    #expect(try read("../../../../../etc/passwd").paths == ["/etc/passwd"])
}

@Test func filesPastTheCapsAreRefusedOrCut() throws {
    #expect(throws: PlaylistFileError.tooLarge(PlaylistFile.maximumBytes + 1)) {
        try PlaylistFile(
            [UInt8](repeating: 0x2F, count: PlaylistFile.maximumBytes + 1), format: .m3u,
            folder: folder)
    }
    #expect(throws: PlaylistFileError.utf16) {
        try PlaylistFile([0xFF, 0xFE, 0x2F, 0], format: .m3u, folder: folder)
    }
    let many = try read(
        String(repeating: "/a.flac\n", count: PlaylistFile.maximumEntries + 5))
    #expect(many.paths.count == PlaylistFile.maximumEntries)
    #expect(
        many.problems == [
            PlaylistFileProblem(line: PlaylistFile.maximumEntries + 1, .tooManyEntries)
        ])
    // A comment or blank line after the last entry allowed isn't an entry past it.
    let full = try read(
        String(repeating: "/a.flac\n", count: PlaylistFile.maximumEntries) + "#end\n\n")
    #expect(full.paths.count == PlaylistFile.maximumEntries && full.problems.isEmpty)
    // Line breaks alone stop at the line cap.
    let breaks = try PlaylistFile(
        [UInt8](repeating: 0x0A, count: PlaylistFile.maximumBytes), format: .m3u, folder: folder)
    #expect(breaks.paths.isEmpty)
    #expect(
        breaks.problems == [PlaylistFileProblem(line: PlaylistFile.maximumLines + 1, .tooManyLines)]
    )
    let noisy = try read(String(repeating: "http://x.invalid/\n", count: 250))
    #expect(noisy.problems.count == PlaylistFile.maximumProblems)
    #expect(noisy.unlistedProblemCount == 250 - PlaylistFile.maximumProblems)
}

@Test func aLinkAFolderOrAnUnknownExtensionIsNotRead() throws {
    let dir = try temporaryFolder()
    let real = dir.appendingPathComponent("real.m3u8")
    try Data("/a.flac\n".utf8).write(to: real)
    #expect(try PlaylistFile(contentsOf: real).paths == ["/a.flac"])
    let link = dir.appendingPathComponent("link.m3u8")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    #expect(throws: PlaylistFileError.self) { try PlaylistFile(contentsOf: link) }
    let folder = dir.appendingPathComponent("folder.m3u")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #expect(throws: PlaylistFileError.self) { try PlaylistFile(contentsOf: folder) }
    #expect(throws: PlaylistFileError.unknownFormat("txt")) {
        try PlaylistFile(contentsOf: dir.appendingPathComponent("list.txt"))
    }
}

@Test func m3u8IsWrittenWithLengthsNamesAndNFCPaths() {
    let decomposed = "/Music/Cafe\u{301}/#1.flac"
    let tracks = [
        PlaylistFileTrack(path: "/Music/a.flac", durationSeconds: 199.6, artist: "A", title: "T"),
        PlaylistFileTrack(
            path: decomposed, durationSeconds: .nan, artist: nil, title: "Two\nLines"),
        PlaylistFileTrack(
            path: "/Music/bad\nname.flac", durationSeconds: 1, artist: nil, title: "x"),
    ]
    let absolute = m3u8Bytes(tracks, relativeTo: nil)
    #expect(
        String(decoding: absolute.bytes, as: UTF8.self)
            == "#EXTM3U\n#EXTINF:200,A - T\n/Music/a.flac\n#EXTINF:-1,Two Lines\n/Music/Café/#1.flac\n"
    )
    #expect(absolute.unwritable == ["/Music/bad\nname.flac"])
    let relative = m3u8Bytes(Array(tracks.prefix(2)), relativeTo: "/Music/Café")
    #expect(
        String(decoding: relative.bytes, as: UTF8.self).split(separator: "\n").filter {
            !$0.hasPrefix("#")
        } == ["../a.flac", "./#1.flac"])
}

@Test func exportedPlaylistsImportBackInOrder() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let ids = Array(try index.trackIDs(sortedBy: .path).reversed().prefix(12))
    let id = try index.createPlaylist(named: "Mix")
    _ = try index.addToPlaylist(id, trackIDs: ids)
    let tracks = try index.playlistFileTracks(
        id, sortedBy: .playlistOrder, ascending: true, groupByAlbumArtist: false)
    let dir = try temporaryFolder().appendingPathComponent("Lists")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for relative in [false, true] {
        let url = dir.appendingPathComponent("Mix \(relative).m3u8")
        #expect(try writeM3U8(tracks, to: url, relativePaths: relative).isEmpty)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\n../") == relative)
        let imported = try index.importPlaylist(
            named: "Back", try PlaylistFile(contentsOf: url), from: url.path)
        #expect(imported.added == ids.count && imported.missing.isEmpty && imported.repeated == 0)
        #expect(try index.playlistTrackIDs(imported.playlistID) == ids)
    }
}

@Test func missingAndRepeatedEntriesAreCountedAndListed() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let paths = try index.rows(ids: try index.trackIDs(sortedBy: .path)).map(\.path)
    let gone = library.root + "/gone.flac"
    let file = try read(
        [paths[0], gone, paths[1], paths[0], "ftp://x.invalid/y"].joined(separator: "\n"))
    let imported = try index.importPlaylist(named: "Some", file, from: "/lists/Some.m3u8")
    #expect(imported.added == 2 && imported.missing == [gone] && imported.repeated == 1)
    #expect(imported.file.problems == [PlaylistFileProblem(line: 5, .scheme("ftp"))])
    #expect(try index.playlistTrackIDs(imported.playlistID).count == 2)
}

@Test func pathsMatchInEitherUnicodeForm() throws {
    let library = try TestLibrary()
    let first = library.path(library.manifest.files.first { $0.malformation == nil }!)
    let named =
        library.root + "/Beyonce\u{301} – De\u{301}ja\u{300} Vu."
        + (first as NSString).pathExtension
    try FileManager.default.copyItem(atPath: first, toPath: named)
    _ = try library.scan()
    let index = try library.index()
    let ids = try index.trackIDs(
        atPaths: [
            named.precomposedStringWithCanonicalMapping, named.decomposedStringWithCanonicalMapping,
            // A share's names are precomposed under a root the index keeps decomposed.
            library.root.decomposedStringWithCanonicalMapping + "/"
                + (named as NSString).lastPathComponent.precomposedStringWithCanonicalMapping,
        ])
    #expect(ids.allSatisfy { $0 != nil } && Set(ids).count == 1)
}
