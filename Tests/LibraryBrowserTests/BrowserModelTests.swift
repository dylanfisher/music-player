import Foundation
import Library
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
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .artist, ascending: true)
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
    async let first: Void = model.setSearch("a")
    async let second: Void = model.setSearch("zzqx")
    _ = await (first, second)
    #expect(model.filter.search == "zzqx")
    #expect(model.trackIDs.isEmpty)
    #expect(changes == 1)
    _ = index
}

@MainActor @Test func sortingReordersByTheColumn() async throws {
    let (model, index) = try await loadedModel()
    for column in TrackColumn.allCases {
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
    let folder = (row.path as NSString).deletingLastPathComponent
    await model.setSource(folder)
    #expect(model.filter.folder == folder)
    #expect(model.trackIDs == (try index.trackIDs(TrackFilter(folder: folder), sortedBy: .artist)))
    #expect(model.genres == (try index.genres(TrackFilter(folder: folder))))
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
