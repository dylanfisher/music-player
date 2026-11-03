import AppKit
import Foundation
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("playlist-file-browser-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor @Test func anImportedPlaylistOpensAndExportsInTheTableSort() async throws {
    let (model, index) = try await writableModel()
    let ids = Array(model.trackIDs.prefix(6).reversed())
    let paths = try index.paths(ids: ids)
    let dir = try temporaryFolder()
    let source = dir.appendingPathComponent("Road Trip.m3u")
    try Data(ids.map { paths[$0]! }.joined(separator: "\r\n").utf8).write(to: source)

    let imported = try await model.importPlaylist(from: source)
    #expect(imported.name == "Road Trip" && imported.added == ids.count)
    #expect(model.shownPlaylist?.name == "Road Trip")
    #expect(model.trackIDs == ids)

    await model.sort(by: .title)
    let out = dir.appendingPathComponent("out.m3u8")
    let (written, unwritable) = try await model.exportPlaylist(
        imported.playlistID, to: out, relativePaths: false)
    #expect(written == ids.count && unwritable.isEmpty)
    let file = try PlaylistFile(contentsOf: out)
    let shown = try index.paths(ids: model.trackIDs)
    #expect(file.paths == model.trackIDs.map { shown[$0]!.precomposedStringWithCanonicalMapping })
}

@MainActor @Test func importingReportsWhatItCouldntAddInTheStatusAndProblems() async throws {
    let databaseURL = try writableBrowserDatabase()
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    let dir = try temporaryFolder()
    let list = dir.appendingPathComponent("Gone.m3u8")
    try Data("/nowhere/a.flac\nhttp://example.invalid/b\n".utf8).write(to: list)
    let huge = dir.appendingPathComponent("Huge.pls")
    try Data(count: PlaylistFile.maximumBytes + 1).write(to: huge)
    browser.importPlaylists(from: [list, huge])
    let deadline = Date().addingTimeInterval(10)
    while browser.status.playlistFileReport.isEmpty, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let report = browser.status.playlistFileReport.map(\.line)
    #expect(
        report == [
            "\(list.path): Imported “Gone”: 0 tracks · 1 not in the library · 1 line skipped",
            "\(list.path): not in the library: /nowhere/a.flac",
            "\(list.path): line 2: a http: address; only files on this Mac are read",
            "couldn't import \(huge.path): "
                + PlaylistFileError.tooLarge(PlaylistFile.maximumBytes + 1).description,
        ], "\(report)")
    #expect(browser.statusText.hasPrefix("Imported “Gone”: 0 tracks"))
    #expect(browser.status.problemLines.starts(with: report))
    // A save panel confirmed after the sidebar moved on writes nothing.
    let shown = try #require(browser.shownPlaylist)
    let out = dir.appendingPathComponent("out.m3u8")
    browser.exportShownPlaylist(shown.id + 1, to: out, relativePaths: false)
    #expect(browser.statusText == "couldn't export the playlist: it's no longer shown")
    #expect(!FileManager.default.fileExists(atPath: out.path))
}

@Test func importAndExportReportsAreCappedWithACount() throws {
    let shown = PlaylistFile.maximumProblems
    var file = try PlaylistFile([], format: .m3u8, folder: "/")
    file.problems = [PlaylistFileProblem(line: 3, .windowsPath)]
    file.unlistedProblemCount = 4
    let result = PlaylistImport(
        playlistID: 1, name: "Mix", source: "/l.m3u", added: 1,
        missing: (0..<(shown + 2)).map { "/gone/\($0)" }, repeated: 1, file: file)
    #expect(
        result.summary
            == "Imported “Mix”: 1 track · \(shown + 2) not in the library · 1 listed twice · 5 lines skipped"
    )
    let lines = result.reportLines
    #expect(lines.count == 1 + shown + 1 + 1 + 1)
    #expect(lines[shown + 1] == "/l.m3u: 2 more not in the library")
    #expect(lines.suffix(2) == ["/l.m3u: line 3: a Windows path", "/l.m3u: 4 more lines skipped"])
    var clean = result
    clean.missing = []
    clean.repeated = 0
    clean.file = try PlaylistFile([], format: .m3u8, folder: "/")
    #expect(clean.reportLines.isEmpty)

    let export = exportReport(
        file: "/out/Mix.m3u8", written: 3, missing: 2, unwritable: ["/a\nb"])
    #expect(
        export.summary
            == "Exported 3 tracks to Mix.m3u8 · 2 not in the library · 1 not written")
    #expect(
        export.lines == [
            "/out/Mix.m3u8: " + export.summary,
            #"/out/Mix.m3u8: not written, since a line can't hold its path: /a\u{A}b"#,
        ])
    #expect(exportReport(file: "/o.m3u8", written: 1, missing: 0, unwritable: []).lines.isEmpty)
}

@MainActor @Test func onlyPlaylistFilesOnAPasteboardAreTaken() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("playlist-files-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let urls = ["/a/Mix.M3U8", "/a/b.flac", "/a/old.m3u", "/a/radio.pls"].map {
        URL(fileURLWithPath: $0) as NSURL
    }
    pasteboard.clearContents()
    pasteboard.writeObjects(urls)
    #expect(
        playlistFileURLs(pasteboard).map(\.path) == ["/a/Mix.M3U8", "/a/old.m3u", "/a/radio.pls"])
    pasteboard.clearContents()
    pasteboard.writeObjects([urls[1]])
    #expect(playlistFileURLs(pasteboard).isEmpty)
}

@MainActor @Test func lineBreaksFromAPlaylistFileCantFakeAReportRow() async throws {
    let (model, _) = try await writableModel()
    let dir = try temporaryFolder()
    let list = dir.appendingPathComponent("Two\nRows.m3u8")
    try Data("file:///gone%0A/x: not in the library: /fake.flac\n".utf8).write(to: list)
    let imported = try await model.importPlaylist(from: list)
    #expect(imported.name == "Two\\u{A}Rows")
    let lines = imported.reportLines
    #expect(lines.count == 2 && lines.allSatisfy { !$0.contains("\n") }, "\(lines)")
    #expect(lines[1].hasSuffix("not in the library: /gone\\u{A}/x: not in the library: /fake.flac"))
    let export = exportReport(
        file: dir.path + "/a\nb.m3u8", written: 0, missing: 0, unwritable: ["/c\nd"])
    #expect(export.lines.allSatisfy { !$0.contains("\n") } && !export.summary.contains("\n"))
}
