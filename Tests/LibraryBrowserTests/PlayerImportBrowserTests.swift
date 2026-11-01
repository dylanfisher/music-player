import Foundation
import SQLite
import Testing

@testable import Library
@testable import LibraryBrowser

private func emptyPlan(_ prefix: PathPrefix? = nil) -> ImportPlan {
    ImportPlan(
        library: PlayerLibrary(player: .swinsian, source: "/s/Library.sqlite"), prefix: prefix)
}

@MainActor @Test func aSlowEarlierPreviewNeverReplacesALaterOne() async throws {
    let slow = PathPrefix(from: "/slow", to: "/a")
    let fast = PathPrefix(from: "/fast", to: "/b")
    let session = PlayerImportSession(shown: emptyPlan()) { prefix in
        if prefix == slow { try await Task.sleep(nanoseconds: 300_000_000) }
        return emptyPlan(prefix)
    }
    let earlier = Task { try await session.preview(slow) }
    try await Task.sleep(nanoseconds: 20_000_000)
    let later = try await session.preview(fast)
    #expect(later?.prefix == fast)
    #expect(try await earlier.value == nil)
    #expect(session.shown.prefix == fast && !session.isPreviewing)
}

@MainActor @Test func aFailedPreviewKeepsThePlanShown() async throws {
    struct Failure: Error {}
    let session = PlayerImportSession(shown: emptyPlan()) { _ in throw Failure() }
    await #expect(throws: Failure.self) {
        try await session.preview(PathPrefix(from: "/x", to: "/y"))
    }
    #expect(session.shown.prefix == nil && !session.isPreviewing)
}

@Test func theImportReportEscapesNamesAndCapsEachList() throws {
    var plan = emptyPlan()
    plan.unmatched = (1...150).map { "/gone/\($0).flac" }
    plan.existingPlaylists = ["Mix\nfake row"]
    plan.library.playlists = [
        PlayerPlaylist(name: "Odd", kind: .unmapped(["the field “kind” has no match here"]))
    ]
    plan.library.problems = [PlayerLibraryProblem("track 3", .noPath)]
    plan.library.unlistedProblemCount = 2
    let lines = plan.detailLines
    let source = "/s/Library.sqlite"
    #expect(lines.filter { $0.hasPrefix("\(source): not in the library: ") }.count == 100)
    #expect(lines.contains("\(source): 50 more not in the library"))
    #expect(lines.contains("\(source): not made, a playlist has the name: Mix\\u{A}fake row"))
    #expect(
        lines.contains(
            "\(source): smart playlist not made, its rules don't map: Odd (the field “kind” has no match here)"
        ))
    #expect(
        lines.suffix(2) == ["\(source): track 3: has no file path", "\(source): 2 more problems"])
    #expect(
        plan.previewLines.contains(
            "Playlists: 0 new (1 skipped, a playlist has the name; 1 skipped, rules that don't map)"
        ))
}

@MainActor @Test func anAppliedImportShowsItsPlaysAndPlaylists() async throws {
    let (model, index) = try await writableModel()
    let ids = Array(model.trackIDs.prefix(2))
    let paths = try index.paths(ids: ids)
    let quoted = ids.map { paths[$0]!.replacingOccurrences(of: "'", with: "''") }
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("player-import-browser-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("Library.sqlite")
    let database = try Database(at: url)
    try database.execute(
        swinsianSchema.map { "CREATE TABLE \($0.name) (\($0.columns.joined(separator: ", ")));" }
            .joined()
                + """
                INSERT INTO track VALUES (1, '\(quoted[0])', 7, NULL, NULL, 3, 0);
                INSERT INTO track VALUES (2, '\(quoted[1])', 0, NULL, NULL, 0, 1);
                INSERT INTO playlist VALUES (1, 'From Swinsian', 0, NULL);
                INSERT INTO playlisttrack VALUES (1, 2, 1), (1, 1, 2);
                """)
    let library = try PlayerLibrary.read(.swinsian, at: url)
    let preview = try await model.importPlan(library, prefix: nil)
    #expect(preview.playsAdded == 7 && preview.ratings == 1 && preview.loved == 1)
    let written = try await model.applyImport(library, prefix: nil)
    #expect(
        written.summary
            == "Imported from Swinsian: +7 plays on 1 track · 1 rating · 1 loved · 1 playlist")
    let made = try #require(model.playlists.first { $0.name == "From Swinsian" })
    #expect(try index.playlistTrackIDs(made.id) == [ids[1], ids[0]])
    #expect(try index.rows(ids: [ids[0]])[0].playCount == 7)
}
