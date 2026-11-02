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
