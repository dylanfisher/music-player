import Foundation
import Settings
import Testing

@testable import Fixtures
@testable import Library

/// The tags of every file the index has a track for.
private func indexedTags(_ library: TestLibrary) -> [(path: String, tags: FixtureTags)] {
    library.manifest.files.compactMap { file in
        let readable = file.malformation.map { $0 == .truncated || $0.isFieldLevel } ?? true
        guard readable, let tags = file.tags else { return nil }
        return (library.path(file), tags)
    }
}

@Test func tracksNarrowByEachPaneLeftToRight() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let tagged = indexedTags(library)
    let genre = try #require(try index.genres().first)
    let artist = try #require(try index.artists(TrackFilter(genre: genre.id)).first)
    let album = try #require(
        try index.albums(TrackFilter(genre: genre.id, artist: artist.id)).first)

    func paths(_ filter: TrackFilter) throws -> Set<String> {
        Set(try index.paths(ids: try index.trackIDs(filter, sortedBy: .path)).values)
    }
    #expect(
        try paths(TrackFilter(genre: genre.id))
            == Set(tagged.filter { $0.tags.genre == genre.name }.map(\.path)))
    #expect(
        try paths(TrackFilter(genre: genre.id, artist: artist.id))
            == Set(
                tagged.filter { $0.tags.genre == genre.name && $0.tags.artist == artist.name }
                    .map(\.path)))
    let all = try paths(TrackFilter(genre: genre.id, artist: artist.id, album: album.id))
    #expect(!all.isEmpty)
    #expect(
        all.allSatisfy { path in
            tagged.contains {
                $0.path == path && $0.tags.album == album.name && $0.tags.artist == artist.name
            }
        })
}

@Test func searchCombinesWithThePanes() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let genre = try #require(try index.genres().first)
    let inGenre = Set(try index.trackIDs(TrackFilter(genre: genre.id), sortedBy: .title))
    let rows = try index.rows(ids: Array(inGenre))
    let word = String(try #require(rows.compactMap(\.artist).first?.split(separator: " ").first))
    let searched = Set(try index.trackIDs(TrackFilter(search: word), sortedBy: .title))
    let both = Set(try index.trackIDs(TrackFilter(genre: genre.id, search: word), sortedBy: .title))
    #expect(!both.isEmpty)
    #expect(both == inGenre.intersection(searched))
}

@Test func rowsComeBackInTheOrderAsked() throws {
    let library = try TestLibrary()
    let before = Date().timeIntervalSince1970
    _ = try library.scan()
    let index = try library.index()
    let ids = try index.trackIDs(sortedBy: .title)
    let reversed = Array(ids.reversed().prefix(25))
    let rows = try index.rows(ids: reversed + [999_999])
    #expect(rows.map(\.id) == reversed)
    let file = try #require(
        library.manifest.files.first {
            $0.malformation == nil && $0.tags?.title != nil && $0.tags?.artist != nil
        })
    let row = try #require(try index.track(path: library.path(file)))
    #expect(row.title == file.tags?.title)
    #expect(row.artist == file.tags?.artist)
    #expect(row.album == file.tags?.album)
    #expect(row.sampleRateHz == file.audio?.sampleRateHz)
    #expect(row.durationSeconds > 0)
    #expect(
        row.addedSeconds >= before.rounded(.down)
            && row.addedSeconds <= Date().timeIntervalSince1970)
    #expect(try index.track(path: library.root + "/nothing.flac") == nil)
    #expect(try index.paths(ids: [row.id, 999_999]) == [row.id: library.path(file)])
}

@Test func dateAddedSurvivesARescanOfAChangedFile() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let file = try #require(library.manifest.files.first { $0.malformation == nil })
    let added = try #require(try index.track(path: library.path(file))).addedSeconds
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: library.path(file))
    #expect(try library.scan().read == 1)
    #expect(try index.track(path: library.path(file))?.addedSeconds == added)
}

@Test func untitledTracksShowTheirFileName() throws {
    #expect(displayName("/Music/A/01 Intro.flac") == "01 Intro")
}

@Test func trackTotalsAddEachListedRowsSizeAndLength() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let ids = try index.trackIDs(sortedBy: .title)
    let rows = try index.rows(ids: ids)
    #expect(rows.contains { $0.sizeBytes > 0 && $0.durationSeconds > 0 })
    let totals = try index.trackTotals(ids: ids)
    #expect(totals.count == ids.count)
    #expect(totals.sizeBytes == rows.reduce(0) { $0 + $1.sizeBytes })
    let seconds = rows.reduce(0) { $0 + $1.durationSeconds }
    #expect(abs(totals.durationSeconds - seconds) < 0.001)
    // A playlist can list a track twice, and a removed track's ID adds nothing.
    let twice = try index.trackTotals(ids: [ids[0], ids[0], -1])
    #expect(twice.count == 2 && twice.sizeBytes == 2 * rows[0].sizeBytes)
    #expect(try index.trackTotals(ids: []) == TrackTotals())
}

@Test func ratingsListEachRatingTheTracksHaveOnce() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let ids = Array(try index.trackIDs(sortedBy: .title).prefix(4))
    #expect(ids.count == 4)
    #expect(try index.ratings(ids: ids) == [0])
    try index.setRating(3, trackIDs: [ids[0], ids[1]])
    try index.setRating(5, trackIDs: [ids[2]])
    #expect(try index.ratings(ids: [ids[0], ids[1]]) == [3])
    #expect(try index.ratings(ids: ids) == [0, 3, 5])
    #expect(try index.ratings(ids: [ids[2], -1]) == [5])
    #expect(try index.ratings(ids: []) == [])
}

@Test func tracksAtPathsReadEachPathsRowInOrder() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let ids = Array(try index.trackIDs(sortedBy: .title).prefix(2))
    let paths = try index.paths(ids: ids)
    let asked = [
        try #require(paths[ids[1]]), "/not/in/the/index.flac", try #require(paths[ids[0]]),
    ]
    #expect(try index.tracks(atPaths: asked).map { $0?.id } == [ids[1], nil, ids[0]])
    #expect(try index.tracks(atPaths: []).isEmpty)
}

/// The albums are counted once each, however many of their tracks the list holds; a track with
/// no album adds none.
@Test func trackTotalsCountEachAlbumOnce() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let ids = try index.trackIDs(sortedBy: .title)
    let rows = try index.rows(ids: ids)
    let albums = Set(rows.compactMap(\.albumID))
    #expect(albums.count > 1)
    #expect(try index.trackTotals(ids: ids + ids).albumCount == albums.count)
    let first = try #require(rows.first { $0.albumID != nil }?.albumID)
    let tracks = rows.filter { $0.albumID == first }.map(\.id)
    #expect(tracks.count > 1)
    #expect(try index.trackTotals(ids: tracks).albumCount == 1)
    #expect(try index.trackTotals(ids: []).albumCount == 0)
}

@Test func trackTotalsFollowAChangeByAnyConnection() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let ids = try index.trackIDs(sortedBy: .title)
    #expect(try index.trackTotals(ids: [ids[0]]).count == 1)
    try index.removeFromLibrary(trackIDs: [ids[0]])
    #expect(try index.trackTotals(ids: [ids[0]]).count == 0)
    #expect(try index.trackTotals(ids: [ids[1]]).count == 1)
    try library.index().removeFromLibrary(trackIDs: [ids[1]])
    #expect(try index.trackTotals(ids: [ids[1]]).count == 0)
}

@Test func trackTotalsKeepTheirSizesThroughAPlayOrARating() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let ids = try index.trackIDs(sortedBy: .title)
    let path = try #require(try index.paths(ids: [ids[0]])[ids[0]])
    _ = try index.trackTotals(ids: ids)
    // A size no file has, which only the kept sizes give.
    index.trackSizes[ids[0]] = TrackSize(bytes: -1, seconds: 0, album: -1)
    try index.recordPlay(path, at: 1000)
    try index.recordSkip(path)
    try index.setRating(3, trackIDs: [ids[0]])
    try index.toggle(.liked, trackIDs: [ids[0]])
    #expect(try index.trackTotals(ids: [ids[0]]).sizeBytes == -1)
    // Another connection's write, between this one's write and the next read, reads them again.
    try index.recordPlay(path, at: 2000)
    try library.index().recordPlay(path, at: 3000)
    #expect(try index.trackTotals(ids: [ids[0]]).sizeBytes > 0)
}
