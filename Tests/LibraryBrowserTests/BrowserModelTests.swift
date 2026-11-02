import Foundation
import Library
import SQLite
import Settings
import Testing

@testable import LibraryBrowser

@MainActor
private func loadedModel(
    _ saved: BrowserState = BrowserState(
        source: nil, genre: nil, artist: nil, album: nil)
) async throws -> (BrowserModel, LibraryIndex) {
    let databaseURL = try browserLibrary.get().databaseURL
    let model = BrowserModel(
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .artist, ascending: true,
        groupByAlbumArtist: false)
    await model.load(saved)
    return (model, try LibraryIndex(at: databaseURL))
}

@MainActor @Test func panesNarrowLeftToRightAndDropSelectionsTheyNoLongerList() async throws {
    let (model, index) = try await loadedModel()
    #expect(model.genres == (try index.genres()))
    #expect(model.trackIDs.count == (try index.trackCount()))

    // An artist that isn't in every genre, and a genre it isn't in.
    let genres = model.genres
    let artist = try #require(
        model.artists.first { artist in
            genres.contains { genre in
                !(try! index.artists(TrackFilter(genre: genre.id))).contains(artist)
            }
        })
    await model.select(.artist, id: artist.id)
    #expect(model.filter.artist == artist.id)
    #expect(model.albums == (try index.albums(TrackFilter(artist: artist.id))))
    #expect(
        model.trackIDs == (try index.trackIDs(TrackFilter(artist: artist.id), sortedBy: .artist)))

    let other = try #require(
        genres.first { !(try! index.artists(TrackFilter(genre: $0.id))).contains(artist) })
    await model.select(.genre, id: other.id)
    #expect(model.filter.genre == other.id)
    #expect(model.filter.artist == nil)
    #expect(model.artists == (try index.artists(TrackFilter(genre: other.id))))
    #expect(model.trackIDs == (try index.trackIDs(TrackFilter(genre: other.id), sortedBy: .artist)))

    await model.select(.genre, id: nil)
    #expect(model.trackIDs.count == (try index.trackCount()))
}

@MainActor @Test func searchCombinesWithThePaneSelection() async throws {
    let (model, index) = try await loadedModel()
    let genre = try #require(model.genres.first)
    await model.select(.genre, id: genre.id)
    let artistWord = try #require(
        try index.rows(ids: model.trackIDs).compactMap(\.artist).first?.split(separator: " ")
            .first)
    await model.setSearch(String(artistWord))
    let expected = try index.trackIDs(
        TrackFilter(genre: genre.id, search: String(artistWord)), sortedBy: .artist)
    #expect(!expected.isEmpty)
    #expect(model.trackIDs == expected)
    // Searching leaves the panes alone.
    #expect(model.filter.genre == genre.id)
    await model.setSearch("")
    #expect(model.trackIDs == (try index.trackIDs(TrackFilter(genre: genre.id), sortedBy: .artist)))
}

@MainActor @Test func theLastKeystrokeWinsWhenQueriesOverlap() async throws {
    let (model, index) = try await loadedModel()
    var changes = 0
    model.changed = { _ in changes += 1 }
    // The first search starts and waits on its query before the second is typed; async let
    // didn't promise that order, so the first could start last under load.
    let first = Task { await model.setSearch("a") }
    await Task.yield()
    await model.setSearch("zzqx")
    await first.value
    #expect(model.filter.search == "zzqx")
    #expect(model.trackIDs.isEmpty)
    #expect(changes == 1)
    _ = index
}

@MainActor @Test func theSameSearchAgainChangesNothing() async throws {
    let (model, _) = try await loadedModel()
    var changes = 0
    model.changed = { _ in changes += 1 }
    await model.setSearch("")
    #expect(changes == 0)
    await model.setSearch("a")
    await model.setSearch("a")
    #expect(changes == 1)
}

@MainActor @Test func sortingReordersByTheColumn() async throws {
    let (model, index) = try await loadedModel()
    for column in TrackColumn.allCases where column.isSortable {
        await model.setSort(column, ascending: false)
        #expect(model.trackIDs == (try index.trackIDs(sortedBy: column, ascending: false)))
    }
    #expect(model.sortColumn == TrackColumn.allCases.last)
    #expect(!model.ascending)
}

@MainActor @Test func savedSelectionsComeBackByNameAndMissingOnesShowAll() async throws {
    let (first, _) = try await loadedModel()
    let genre = try #require(first.genres.last)
    await first.select(.genre, id: genre.id)
    let artist = try #require(first.artists.first)
    await first.select(.artist, id: artist.id)
    let saved = first.state
    #expect(saved.genre == genre.name)
    #expect(saved.artist == artist.name)

    let (restored, _) = try await loadedModel(saved)
    #expect(restored.filter.genre == genre.id)
    #expect(restored.filter.artist == artist.id)
    #expect(restored.trackIDs == first.trackIDs)

    let (gone, index) = try await loadedModel(
        BrowserState(source: nil, genre: "No Such Genre", artist: nil, album: "Nor Album"))
    #expect(gone.filter.genre == nil)
    #expect(gone.filter.album == nil)
    #expect(gone.trackIDs.count == (try index.trackCount()))
}

@MainActor @Test func aWatchedFolderNarrowsEverything() async throws {
    let (model, index) = try await loadedModel()
    let row = try #require(try index.rows(ids: [model.trackIDs[0]]).first)
    let folder = BrowserSource.folder((row.path as NSString).deletingLastPathComponent)
    await model.setSource(folder)
    #expect(model.filter.source == folder)
    #expect(model.trackIDs == (try index.trackIDs(TrackFilter(source: folder), sortedBy: .artist)))
    #expect(model.genres == (try index.genres(TrackFilter(source: folder))))
    #expect(model.state.source == folder)
}

@MainActor @Test func aRefreshKeepsTheSelectedRowsByID() async throws {
    let (model, _) = try await loadedModel()
    let picked: Set<Int64> = [model.trackIDs[3], model.trackIDs[10]]
    var reasons: [BrowserChange.Reason] = []
    model.changed = { reasons.append($0.reason) }
    await model.setSort(.title, ascending: true)
    await model.refresh()
    #expect(reasons == [.user, .libraryChanged])
    let rows = model.rows(holding: picked)
    #expect(Set(rows.map { model.trackIDs[$0] }) == picked)
}

@MainActor @Test func aDoubleClickQueuesTheVisibleListInTableOrder() async throws {
    let (model, index) = try await loadedModel()
    let request = try #require(try await model.playRequest(selected: [5], clicked: 5))
    #expect(request.first == 5)
    #expect(request.urls.count == model.trackIDs.count)
    #expect(request.urls[5].path == (try index.rows(ids: [model.trackIDs[5]]))[0].path)

    let several = try #require(try await model.playRequest(selected: [2, 4], clicked: 4))
    #expect(several.first == 0)
    let paths = try index.paths(ids: model.trackIDs)
    #expect(several.urls.prefix(3).map(\.path) == [2, 4, 5].map { paths[model.trackIDs[$0]]! })
    #expect(several.urls.count == model.trackIDs.count - 3)
}

@MainActor @Test func aChangeThatOvertakesAnotherCarriesItAlong() async throws {
    let (model, index) = try await loadedModel()
    let genre = try #require(model.genres.first)
    let word = String(
        try #require(
            try index.rows(ids: try index.trackIDs(TrackFilter(genre: genre.id), sortedBy: .artist))
                .compactMap(\.artist).first?.split(separator: " ").first))
    async let picked: Void = model.select(.genre, id: genre.id)
    async let typed: Void = model.setSearch(word)
    _ = await (picked, typed)
    #expect(model.filter.genre == genre.id)
    #expect(model.filter.search == word)
    #expect(model.artists == (try index.artists(TrackFilter(genre: genre.id))))
    #expect(
        model.trackIDs
            == (try index.trackIDs(TrackFilter(genre: genre.id, search: word), sortedBy: .artist)))
}

@MainActor @Test func aSortThatFailsLeavesTheSortAsShown() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("browser-failing-\(UUID().uuidString)")
    let databaseURL = directory.appendingPathComponent("library.sqlite")
    _ = try LibraryIndex(at: databaseURL)
    let model = BrowserModel(
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .artist, ascending: true,
        groupByAlbumArtist: false)
    var failures: [String] = []
    model.failed = { failures.append($0) }
    await model.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))
    #expect(failures.isEmpty)
    let breaker = try SQLite.Database(at: databaseURL)
    try breaker.execute("DROP TABLE tracks")
    await model.setSort(.title, ascending: false)
    #expect(failures.count == 1)
    #expect(model.sortColumn == .artist)
    #expect(model.ascending)
}

@MainActor @Test func groupingByAlbumArtistReloadsTheArtistPaneAndKeepsAnArtistListedInBoth()
    async throws
{
    let (model, index) = try await loadedModel()
    #expect(model.artists == (try index.artists()))
    let grouped = try index.artists(TrackFilter(groupByAlbumArtist: true))
    let kept = try #require(model.artists.first { grouped.contains($0) })
    await model.select(.artist, id: kept.id)
    await model.setGroupByAlbumArtist(true)
    #expect(model.filter.groupByAlbumArtist)
    #expect(model.artists == grouped)
    #expect(model.filter.artist == kept.id)
    #expect(
        model.trackIDs
            == (try index.trackIDs(
                TrackFilter(artist: kept.id, groupByAlbumArtist: true), sortedBy: .artist)))
    // Showing the whole library, as the palette does, keeps the grouping.
    await model.showOnly(.genre, id: try #require(model.genres.first).id)
    #expect(model.filter.groupByAlbumArtist)
}

@Test func aPlayQueryIsAnEntryWhenItStartsWithAPanesPrefix() {
    #expect(PlayQuery("album:Kind of Blue") == .entry(.album, "Kind of Blue"))
    #expect(PlayQuery("Artist:Miles Davis") == .entry(.artist, "Miles Davis"))
    #expect(PlayQuery("genre:") == .entry(.genre, ""))
    #expect(PlayQuery("kind of blue") == .search("kind of blue"))
    #expect(PlayQuery("albums: x") == .search("albums: x"))
}

@MainActor @Test func aPlayQueryShowsItsTracksInTheWholeLibraryAndPlaysThemAll() async throws {
    let (model, index) = try await loadedModel()
    await model.select(.genre, id: try #require(model.genres.first).id)
    let album = try #require(
        try index.albums().first { album in
            try index.albums().filter { TypeSelect.fold($0.name) == TypeSelect.fold(album.name) }
                .count == 1
        })
    let byAlbum = try await model.show(PlayQuery("album:" + album.name.uppercased()))
    #expect(model.filter.album == album.id)
    #expect(model.filter.genre == nil)
    let albumTracks = try index.trackIDs(TrackFilter(album: album.id), sortedBy: .artist)
    #expect(
        byAlbum.urls
            == (try index.paths(ids: albumTracks)).sorted { a, b in
                albumTracks.firstIndex(of: a.key)! < albumTracks.firstIndex(of: b.key)!
            }.map { URL(fileURLWithPath: $0.value) })
    #expect(byAlbum.first == 0)

    let word = try #require(album.name.split(separator: " ").first.map(String.init))
    let bySearch = try await model.show(.search(word))
    #expect(model.filter.search == word)
    #expect(model.filter.album == nil)
    #expect(
        bySearch.urls.count
            == (try index.trackIDs(TrackFilter(search: word), sortedBy: .artist)).count)
}

@MainActor @Test func aPlayQueryThatNamesNothingIsRefusedAndSaysSo() async throws {
    let (model, _) = try await loadedModel()
    await #expect(throws: PlayQueryError.noEntry(.album, "No Such Album")) {
        try await model.show(PlayQuery("album:No Such Album"))
    }
    await #expect(throws: PlayQueryError.nothingMatches(.search("zzqqxx"))) {
        try await model.show(.search("zzqqxx"))
    }
    #expect(
        PlayQueryError.several(.album, "Hits", artists: ["A", nil, "C", "D", "E", "F", "G"])
            .description
            == "7 albums are named Hits, by A, no artist, C, D, E and 2 more; play a search of the"
            + " name and the artist instead")
}
