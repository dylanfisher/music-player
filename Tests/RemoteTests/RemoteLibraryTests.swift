import Artwork
import Commands
import Foundation
import Settings
import Testing

@testable import Fixtures
@testable import Library
@testable import LocalNetwork
@testable import Remote

/// A fixture library scanned once into a database of its own, apart from the other test
/// targets' copies. 150 files give albums with art and albums without.
private let scanned = Result { () throws -> URL in
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/remote-tests")
    _ = try generateFixtures(count: 150, in: root)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "remote-library-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appendingPathComponent("library.sqlite", isDirectory: false)
    _ = try LibraryScanner(databaseURL: databaseURL).scan(
        WatchedFolder(path: root.path, kind: .local))
    return databaseURL
}

private func library(grouped: Bool = false) throws -> (RemoteLibrary, LibraryIndex) {
    let databaseURL = try scanned.get()
    return (
        RemoteLibrary(
            databaseURL: databaseURL,
            thumbnails: ThumbnailStore(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "remote-art-\(UUID().uuidString)", isDirectory: true)),
            groupByAlbumArtist: grouped),
        try LibraryIndex(at: databaseURL)
    )
}

private func json(_ reply: RemoteReply) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(reply.body), options: [.fragmentsAllowed])
}

private func read(
    _ library: RemoteLibrary, _ path: String, _ query: String? = nil, tag: String? = nil
)
    async throws -> RemoteReply
{
    try #require(await library.reply(path, query: query, ifNoneMatch: tag))
}

@Test func listsComeWholeAsCompactArraysOfWhatTheBrowserQueriesGive() async throws {
    let (remote, index) = try library()
    let genres = try json(try await read(remote, RemoteRoute.genres)) as? [String: Any]
    #expect(
        (genres?["rows"] as? [[Any]])?.map { "\($0[0]) \($0[1])" }
            == (try index.genres().map { "\($0.id) \($0.name)" }))
    let genre = try #require(try index.genres().first)
    let artists = try json(try await read(remote, RemoteRoute.artists, "genre=\(genre.id)"))
    #expect(
        ((artists as? [String: Any])?["rows"] as? [[Any]])?.map { "\($0[0]) \($0[1])" }
            == (try index.artists(TrackFilter(genre: genre.id)).map { "\($0.id) \($0.name)" }))
    let albums = try json(try await read(remote, RemoteRoute.albums))
    let rows = try #require((albums as? [String: Any])?["rows"] as? [[Any]])
    #expect(rows.count == (try index.albums().count))
    #expect(rows.allSatisfy { $0.count == 3 })
}

@Test func tracksComeByPositionWithTheirTotalSortedAsTheBrowserSortsThem() async throws {
    let (remote, index) = try library()
    let whole = try index.trackNames(TrackFilter(), sortedBy: .title, ascending: false)
    #expect(whole.count > 100)
    for offset in [0, 50, whole.count - 3, whole.count] {
        let reply = try json(
            try await read(
                remote, RemoteRoute.tracks, "sort=title&descending=1&offset=\(offset)&limit=40")
        )
        let range = try #require(reply as? [String: Any])
        #expect(range["total"] as? Int == whole.count)
        #expect((range["stamp"] as? String)?.hasPrefix("\"") == true)
        #expect(range["offset"] as? Int == offset)
        let ids = (range["rows"] as? [[Any]])?.map { $0[0] as? Int64 }
        let expected = whole.indices.clamped(to: offset..<(offset + 40))
        #expect(ids == whole[expected.clamped(to: whole.indices)].map { $0.id })
    }
    let album = try #require(
        try index.albums().first {
            (try? index.trackIDs(TrackFilter(album: $0.id), sortedBy: .album).count) ?? 0 > 1
        })
    let listed = try json(
        try await read(
            remote, RemoteRoute.tracks, "album=\(album.id)&sort=album&offset=0&limit=200"))
    let ids = ((listed as? [String: Any])?["rows"] as? [[Any]])?.compactMap { $0[0] as? Int64 }
    let files = try await remote.files(argument: "album:\(album.id)", queueing: true)
    let paths = try index.paths(ids: try #require(ids))
    // The page lists an album in the order Play Tracks plays it.
    #expect(try #require(ids).compactMap { paths[$0] } == files.urls.map(\.path))
}

@Test func aReadOfAnUnchangedLibraryIsA304UntilAnotherConnectionChangesIt() async throws {
    let (remote, index) = try library()
    let first = try await read(remote, RemoteRoute.artists)
    let tag = try #require(first.fields.first { $0.0 == "ETag" }?.1)
    let again = try await read(remote, RemoteRoute.artists, tag: tag)
    #expect(again.status == .notModified)
    #expect(again.body.isEmpty)
    let track = try #require(try index.trackIDs(sortedBy: .path).first)
    try index.setRating(3, trackIDs: [track])
    let changed = try await read(remote, RemoteRoute.artists, tag: tag)
    #expect(changed.status == .ok)
    #expect(changed.fields.first { $0.0 == "ETag" }?.1 != tag)
    // The grouping changes what the Artists list holds, so it's in the tag too.
    let (grouped, _) = try library(grouped: true)
    let other = try await read(grouped, RemoteRoute.artists, tag: tag)
    #expect(other.status == .ok)
}

@Test func aQueryStringOutsideWhatTheReadTakesIsRefusedEvenWhenItsTagMatches() async throws {
    let (remote, index) = try library()
    let tag = try #require(
        try await read(remote, RemoteRoute.genres).fields.first { $0.0 == "ETag" }?.1)
    let total = try index.trackCount(TrackFilter())
    #expect(
        try await read(remote, RemoteRoute.tracks, "offset=\(total + 1)&limit=5", tag: tag).status
            == .badRequest)
    let refused: [(String, String)] = [
        (RemoteRoute.genres, "genre=1"), (RemoteRoute.artists, "genre=x"),
        (RemoteRoute.artists, "genre=1&genre=2"), (RemoteRoute.artists, "genre=0"),
        (RemoteRoute.tracks, "offset=0"), (RemoteRoute.tracks, "offset=0&limit=201"),
        (RemoteRoute.tracks, "offset=0&limit=0"), (RemoteRoute.tracks, "offset=-1&limit=5"),
        (RemoteRoute.tracks, "offset=0&limit=5&sort=rowNumber"),
        (RemoteRoute.tracks, "offset=0&limit=5&descending=yes"),
        (RemoteRoute.search, ""),
        (RemoteRoute.search, "q=" + String(repeating: "a", count: 257)),
        (RemoteRoute.covers, "albums=1,,2"), (RemoteRoute.albums, "nope"),
    ]
    for (path, query) in refused {
        #expect(try await read(remote, path, query).status == .badRequest, "\(path)?\(query)")
        #expect(
            try await read(remote, path, query, tag: tag).status == .badRequest,
            "\(path)?\(query) with its tag")
    }
    #expect(await remote.reply("/api/nothing", query: nil, ifNoneMatch: nil) == nil)
}

@Test func aSearchFindsArtistsAlbumsAndTracksTwentyOfEach() async throws {
    let (remote, index) = try library()
    // Past the first 20, so a search that listed every artist wouldn't find it.
    let artist = try #require(try index.artists().last)
    let word = try #require(artist.name.split(separator: " ").first)
    let found = try #require(
        try json(try await read(remote, RemoteRoute.search, "q=\(word)")) as? [String: Any])
    let artists = try #require(found["artists"] as? [[Any]])
    #expect(artists.contains { $0[0] as? Int64 == artist.id })
    for kind in ["artists", "albums", "tracks"] {
        #expect(((found[kind] as? [[Any]])?.count ?? 99) <= RemoteLibrary.searchLimit)
    }
    #expect(!(found["tracks"] as? [[Any]] ?? []).isEmpty)
    let none = try #require(
        try json(try await read(remote, RemoteRoute.search, "q=qqqzzzxxx")) as? [String: Any])
    for kind in ["artists", "albums", "tracks"] {
        #expect((none[kind] as? [[Any]])?.isEmpty == true, "\(kind)")
    }
}

/// A word of letters only in `name`, which the search's tokenizer keeps whole.
private func searchWord(_ name: String) -> String? {
    let words = name.split(separator: " ").filter { $0.count > 2 && $0.allSatisfy(\.isLetter) }
    return words.first.map { String($0) }
}

private func found(_ remote: RemoteLibrary, _ q: String) async throws -> [String: [[Any]]] {
    let reply = try await read(
        remote, RemoteRoute.search,
        "q=" + q.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
    #expect(reply.status == .ok, "\(q)")
    let found = try #require(try json(reply) as? [String: Any])
    return try found.mapValues { try #require($0 as? [[Any]]) }
}

/// The palette's prefixes narrow a search to one kind, matched in its own tags, by its name
/// or short name in any case; a kind the remote doesn't list finds nothing, and a word that
/// names no kind is searched as typed (ADR 0161, 0220).
@Test func aPrefixedSearchListsOnlyThatKind() async throws {
    let (remote, index) = try library()
    func matches(_ name: Any, _ word: String) -> Bool {
        (name as? String)?.range(of: word, options: [.caseInsensitive, .diacriticInsensitive])
            != nil
    }
    let album = try #require(try index.albums().first { searchWord($0.name) != nil })
    let albumWord = try #require(searchWord(album.name))
    for q in ["a:\(albumWord)", "ALBUM: \(albumWord.uppercased())", "A:\(albumWord)"] {
        let albums = try await found(remote, q)
        #expect(albums["albums"]?.contains { $0[0] as? Int64 == album.id } == true, "\(q)")
        #expect(albums["albums"]?.allSatisfy { matches($0[1], albumWord) } == true, "\(q)")
        #expect(albums["artists"]?.isEmpty == true && albums["tracks"]?.isEmpty == true, "\(q)")
    }
    let artist = try #require(try index.artists().first { searchWord($0.name) != nil })
    let artistWord = try #require(searchWord(artist.name))
    for q in ["ar:\(artistWord)", "Artist:\(artistWord)"] {
        let artists = try await found(remote, q)
        #expect(artists["artists"]?.contains { $0[0] as? Int64 == artist.id } == true, "\(q)")
        #expect(artists["albums"]?.isEmpty == true && artists["tracks"]?.isEmpty == true, "\(q)")
    }
    let title = try #require(
        try index.trackNames(TrackFilter(), sortedBy: .title, window: 0..<200)
            .compactMap { searchWord($0.title) }.first)
    for q in ["t:\(title)", "track: \(title)"] {
        let tracks = try await found(remote, q)
        #expect(tracks["tracks"]?.isEmpty == false, "\(q)")
        #expect(tracks["tracks"]?.allSatisfy { matches($0[1], title) } == true, "\(q)")
        #expect(tracks["artists"]?.isEmpty == true && tracks["albums"]?.isEmpty == true, "\(q)")
    }
    for q in ["g:\(albumWord)", "playlist:\(albumWord)"] {
        #expect(try await found(remote, q).values.allSatisfy(\.isEmpty), "\(q)")
    }
    // A query with no word to match finds nothing, rather than the first of everything.
    for q in ["a:", "t: ", ":", "!!!", "ar: !!"] {
        #expect(try await found(remote, q).values.allSatisfy(\.isEmpty), "\(q)")
    }
    // Searched as typed, the unknown word matches nothing; dropped, the album would match.
    #expect(try await found(remote, "zzq: \(albumWord)").values.allSatisfy(\.isEmpty))
    #expect(try await found(remote, albumWord)["albums"]?.isEmpty == false)
}

/// A track list takes the same prefixes, so the search's songs play as it lists them, and
/// refuses a kind it can't be narrowed to.
@Test func aTrackListReadsTheSearchsPrefix() async throws {
    let (remote, index) = try library()
    let title = try #require(
        try index.trackNames(TrackFilter(), sortedBy: .title, window: 0..<200)
            .compactMap { searchWord($0.title) }.first)
    let q = "t%3A" + title
    let range = try #require(
        try json(try await read(remote, RemoteRoute.tracks, "q=\(q)&offset=0&limit=200"))
            as? [String: Any])
    let rows = try #require(range["rows"] as? [[Any]])
    var filter = TrackFilter(search: title)
    filter.searchField = .title
    #expect(rows.count == (try index.trackCount(filter)))
    #expect(!rows.isEmpty)
    for q in ["g%3Arock", "t%3A", "%21%21%21"] {
        #expect(
            try await read(remote, RemoteRoute.tracks, "q=\(q)&offset=0&limit=20").status
                == .badRequest, "\(q)")
        await #expect(throws: RemoteRefusal.self, "\(q)") {
            try await remote.files(list: "q=\(q)&playFrom=1")
        }
    }
}

@Test func coversNameEachAlbumsArtWhichComesAtTwoSizesForGood() async throws {
    let (remote, index) = try library()
    let albums = try index.albums().map(\.id)
    let reply = try await read(
        remote, RemoteRoute.covers,
        "albums=" + albums.prefix(200).map(String.init).joined(separator: ","))
    let covers = try #require(try json(reply) as? [String: String])
    #expect(!covers.isEmpty && covers.count < albums.count)
    let id = try #require(covers.values.first)
    let small = try #require(try await remote.art(id, size: "s"))
    let large = try #require(try await remote.art(id, size: "l"))
    #expect(small.type == "image/jpeg" || small.type == "image/png")
    #expect(small.bytes.count < large.bytes.count)
    let parts = id.split(separator: "-")
    #expect(
        try await remote.art("\(parts[0])-" + String(repeating: "0", count: 32), size: "s") == nil)
    #expect(try await remote.art(id, size: "x") == nil)
    #expect(try await remote.art("+\(id)", size: "s") == nil)
}

@Test func playTracksTakesIDsOrAnAlbumFromATrackAndRefusesTheRest() async throws {
    let (remote, index) = try library()
    let ids = Array(try index.trackIDs(sortedBy: .path).prefix(3))
    let paths = try index.paths(ids: ids)
    let picked = try await remote.files(
        argument: "tracks:" + ids.reversed().map(String.init).joined(separator: ","),
        queueing: false)
    #expect(picked.urls.map(\.path) == ids.reversed().map { paths[$0]! })
    #expect(picked.first == 0)
    let album = try #require(try index.albums().first)
    let tracks = try index.trackIDs(
        TrackFilter(album: album.id, groupByAlbumArtist: true), sortedBy: .album)
    let last = try #require(tracks.last)
    let played = try await remote.files(argument: "album:\(album.id):\(last)", queueing: false)
    #expect(played.first == tracks.count - 1)
    for argument in [
        "tracks:", "tracks:1,,2", "tracks:0", "album:\(album.id):\(last)",
        "tracks:" + Array(repeating: "1", count: 101).joined(separator: ","), "album:x", "1,2",
    ] {
        await #expect(throws: RemoteRefusal.self, "\(argument)") {
            try await remote.files(argument: argument, queueing: true)
        }
    }
    let other = try #require(try index.trackIDs(sortedBy: .path).first { !tracks.contains($0) })
    await #expect(throws: RemoteRefusal.self) {
        try await remote.files(argument: "album:\(album.id):\(other)", queueing: false)
    }
    await #expect(throws: RemoteRefusal.self) {
        try await remote.files(argument: "tracks:999999999", queueing: false)
    }
}

@Test func playListPlaysTheWholeListAsTheTracksReadListsItFromAStartTrack() async throws {
    let (remote, index) = try library()
    let whole = try index.trackIDs(TrackFilter(), sortedBy: .title, ascending: false)
    let paths = try index.paths(ids: whole)
    let start = whole[whole.count / 2]
    let played = try await remote.files(list: "sort=title&descending=1&playFrom=\(start)")
    #expect(played.urls.count == whole.count)
    #expect(played.urls.map(\.path) == whole.map { paths[$0]! })
    #expect(played.first == whole.count / 2)
    // A search's tracks play in the order the search lists them.
    let artist = try #require(try index.artists().last)
    let word = String(try #require(artist.name.split(separator: " ").first))
    let found = try json(try await read(remote, RemoteRoute.search, "q=\(word)")) as? [String: Any]
    let first = try #require((found?["tracks"] as? [[Any]])?.first?[0] as? Int64)
    let searched = try await remote.files(list: "q=\(word)&playFrom=\(first)")
    #expect(searched.first == 0)
    #expect(searched.urls.first?.path == (try index.paths(ids: [first])[first]))
    for argument in [
        "sort=title", "playFrom=999999999", "playFrom=\(start)&offset=0",
        "q=\(word)&playFrom=\(start)&q=a",
        "sort=rowNumber&playFrom=\(start)",
    ] {
        await #expect(throws: RemoteRefusal.self, "\(argument)") {
            try await remote.files(list: argument)
        }
    }
}

@Test func queueRowsNameEachFileAndOneTheIndexLacksByItsName() async throws {
    let (remote, index) = try library()
    let id = try #require(try index.trackIDs(sortedBy: .path).first)
    let path = try #require(try index.paths(ids: [id])[id])
    let rows = try await remote.queueRows([path, "/gone/Some Song.flac"])
    #expect(rows.map(\.id) == [id, nil])
    #expect(rows[1].title == "Some Song")
}

/// Counts the reads running at once, each held until the test lets them all go.
private final class Held: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private(set) var most = 0
    let release = DispatchSemaphore(value: 0)

    func read() {
        lock.withLock {
            running += 1
            most = max(most, running)
        }
        release.wait()
        lock.withLock { running -= 1 }
    }

    var now: Int { lock.withLock { running } }
}

@Test func coverReadsRunFourAtOnceAndRefuseThoseBeyondTheWaitingCap() async throws {
    let reads = RemoteArtReads()
    let held = Held()
    let total = RemoteArtReads.runningLimit + RemoteArtReads.waitingLimit
    let tasks = (0..<total).map { _ in Task { try await reads.run { held.read() } } }
    try await waitFor { held.now == RemoteArtReads.runningLimit && reads.admitted == total }
    await #expect(throws: RemoteBusy.self) { try await reads.run { held.read() } }
    for _ in 0..<total { held.release.signal() }
    for task in tasks { try await task.value }
    #expect(held.most == RemoteArtReads.runningLimit)
    // Room again once they're done.
    held.release.signal()
    try await reads.run { held.read() }
}
