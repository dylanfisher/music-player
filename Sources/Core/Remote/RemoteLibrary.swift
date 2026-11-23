import Artwork
import Commands
import Foundation
import Library
import LocalNetwork
import Metadata
import Settings

/// The web remote's library reads (ADR 0215), through the queries the library window runs, on a
/// query-only connection of its own so a phone never waits for the window or holds it up.
/// Lists are compact arrays; every read carries an `ETag` from the index's change stamp and
/// answers a matching `If-None-Match` with a 304.
public actor RemoteLibrary {
    /// The positions one `/api/tracks` or `/api/queue` read returns at most.
    static let rangeLimit = 200
    /// What a search returns of each kind.
    static let searchLimit = 20
    /// The most albums one `/api/covers` read names.
    static let coversLimit = 200
    /// The longest side of each size of cover, in pixels: a list row's, and Now Playing's.
    static let artPixels = ["s": 160, "l": 640]

    private let databaseURL: URL
    private var opened: LibraryIndex?
    private let thumbnails: ThumbnailStore
    private let read: ArtRead
    /// `library.groupByAlbumArtist`, which the app sets as it changes.
    private var groupByAlbumArtist: Bool
    private let artReads: RemoteArtReads
    /// Tells this launch's tags from another's, whose change stamps start over.
    private let launch: String

    public init(
        databaseURL: URL, thumbnails: ThumbnailStore,
        groupByAlbumArtist: Bool, read: @escaping ArtRead = readArtBytes
    ) {
        self.databaseURL = databaseURL
        self.thumbnails = thumbnails
        self.groupByAlbumArtist = groupByAlbumArtist
        self.read = read
        artReads = RemoteArtReads()
        launch = RemoteService.newInstanceID().prefix(8).description
    }

    /// The cover's ID for `row`'s art, `<track ID>-<picture name>`, nil when it has none. The
    /// name changes with the file, so a URL holding it always means the same picture.
    public static func artID(_ row: TrackRow) -> String? {
        row.art.map { art in
            "\(row.id)-"
                + ThumbnailStore.pictureName(
                    art, path: row.path,
                    stamp: FileStamp(sizeBytes: row.sizeBytes, modifiedSeconds: row.modifiedSeconds)
                )
        }
    }

    /// Follows `library.groupByAlbumArtist`, which the artist lists and their tags follow.
    public func group(byAlbumArtist on: Bool) { groupByAlbumArtist = on }

    private func index() throws -> LibraryIndex {
        if let opened { return opened }
        let made = try LibraryIndex.queryOnly(at: databaseURL)
        opened = made
        return made
    }

    /// A library read's reply, by path and the query string after its `?`; nil for a path
    /// that isn't one. The query is checked before the tag, so a malformed one is a 400 even
    /// when the tag matches.
    public func reply(_ path: String, query text: String?, ifNoneMatch: String?) -> RemoteReply? {
        let query = RemoteQuery(text)
        let prepare: (LibraryIndex, RemoteQuery, Bool) throws -> Read
        switch path {
        case RemoteRoute.genres: prepare = Self.genres
        case RemoteRoute.artists: prepare = Self.artists
        case RemoteRoute.albums: prepare = Self.albums
        case RemoteRoute.tracks: prepare = Self.tracks
        case RemoteRoute.search: prepare = Self.search
        case RemoteRoute.covers: prepare = Self.covers
        default: return nil
        }
        do {
            let index = try index()
            let grouped = groupByAlbumArtist
            let read = try prepare(index, query, grouped)
            let tag =
                "\"\(launch)-\(try index.changeStamp().map(String.init).joined(separator: "-"))"
                + "-\(grouped ? 1 : 0)\""
            if ifNoneMatch == tag {
                return RemoteReply(.notModified, fields: [(HTTPWord.etag, tag), Self.revalidate])
            }
            var reply = try read(tag)
            if reply.status == .ok { reply.fields = [(HTTPWord.etag, tag), Self.revalidate] }
            return reply
        } catch let refusal as RemoteRefusal {
            return RemoteAPI.error(.badRequest, "\(refusal)")
        } catch {
            return RemoteAPI.error(.serviceUnavailable, "the library couldn't be read: \(error)")
        }
    }

    /// A read whose query was checked, run with the reply's tag.
    private typealias Read = (String) throws -> RemoteReply

    /// Kept, but asked about again before each use, since the tag says whether it changed.
    private static let revalidate = (HTTPWord.cacheControl, HTTPWord.noCache)

    private static func genres(_ index: LibraryIndex, _ query: RemoteQuery, _ grouped: Bool)
        throws -> Read
    {
        try query.only([])
        return { _ in RemoteAPI.reply(EntryList(try index.genres(), albums: false)) }
    }

    private static func artists(_ index: LibraryIndex, _ query: RemoteQuery, _ grouped: Bool)
        throws -> Read
    {
        try query.only([RemoteQuery.genre])
        let filter = TrackFilter(
            genre: try query.id(RemoteQuery.genre), groupByAlbumArtist: grouped)
        return { _ in RemoteAPI.reply(EntryList(try index.artists(filter), albums: false)) }
    }

    private static func albums(_ index: LibraryIndex, _ query: RemoteQuery, _ grouped: Bool)
        throws -> Read
    {
        try query.only([RemoteQuery.genre, RemoteQuery.artist])
        let filter = TrackFilter(
            genre: try query.id(RemoteQuery.genre), artist: try query.id(RemoteQuery.artist),
            groupByAlbumArtist: grouped)
        return { _ in RemoteAPI.reply(EntryList(try index.albums(filter), albums: true)) }
    }

    /// The keys that describe a track list, as `/api/tracks` reads it and Play List plays it.
    static let listKeys: Set<String> = [
        RemoteQuery.genre, RemoteQuery.artist, RemoteQuery.album, RemoteQuery.text,
        RemoteQuery.sort, RemoteQuery.descending,
    ]

    /// The track list `query` describes: its filter, the column it's sorted by and which way.
    static func list(_ query: RemoteQuery, grouped: Bool) throws -> (
        filter: TrackFilter, column: TrackColumn, ascending: Bool
    ) {
        var filter = trackFilter(
            genre: try query.id(RemoteQuery.genre), artist: try query.id(RemoteQuery.artist),
            album: try query.id(RemoteQuery.album), grouped: grouped)
        if query.has(RemoteQuery.text) {
            guard let search = try query.search() else {
                throw RemoteRefusal("q names a kind a track list can't be narrowed to")
            }
            filter.search = search.text
            filter.searchField = search.field
        }
        return (filter, try query.column() ?? .artist, !(try query.flag(RemoteQuery.descending)))
    }

    private static func tracks(_ index: LibraryIndex, _ query: RemoteQuery, _ grouped: Bool)
        throws -> Read
    {
        try query.only(listKeys.union([RemoteQuery.offset, RemoteQuery.limit]))
        let list = try list(query, grouped: grouped)
        let window = try query.window(limit: rangeLimit)
        let total = try index.trackCount(list.filter)
        guard window.lowerBound <= total else {
            throw RemoteRefusal("offset \(window.lowerBound) is past the list's \(total) tracks")
        }
        return { tag in
            RemoteAPI.reply(
                TrackRange(
                    total: total, offset: window.lowerBound, stamp: tag,
                    rows: try index.trackNames(
                        list.filter, sortedBy: list.column, ascending: list.ascending,
                        window: window
                    ).map(TrackLine.init)))
        }
    }

    /// An album alone lists its tracks in disc and track order whoever plays on them, as the
    /// table lists an album when it groups by album artist; the album's ID is the same either
    /// way, so the grouping changes only the order.
    static func trackFilter(genre: Int64?, artist: Int64?, album: Int64?, grouped: Bool)
        -> TrackFilter
    {
        TrackFilter(
            genre: genre, artist: artist, album: album,
            groupByAlbumArtist: grouped || (album != nil && genre == nil && artist == nil))
    }

    private static func search(_ index: LibraryIndex, _ query: RemoteQuery, _ grouped: Bool)
        throws -> Read
    {
        try query.only([RemoteQuery.text])
        // A kind the remote doesn't list finds nothing, as the palette lists nothing of a
        // kind it doesn't have.
        let search = try query.search()
        var filter = TrackFilter(search: search?.text ?? "", groupByAlbumArtist: grouped)
        filter.searchField = search?.field
        let lists = { (field: SearchField) in
            search.map { $0.field == nil || $0.field == field } ?? false
        }
        return { _ in
            RemoteAPI.reply(
                Found(
                    artists: lists(.artist)
                        ? EntryList(
                            try index.searchEntries(.artists, filter, limit: searchLimit),
                            albums: false
                        ).rows : [],
                    albums: lists(.album)
                        ? EntryList(
                            try index.searchEntries(.albums, filter, limit: searchLimit),
                            albums: true
                        ).rows : [],
                    tracks: lists(.title)
                        ? try index.trackNames(filter, sortedBy: .artist, window: 0..<searchLimit)
                            .map(TrackLine.init) : []))
        }
    }

    private static func covers(_ index: LibraryIndex, _ query: RemoteQuery, _ grouped: Bool)
        throws -> Read
    {
        try query.only([RemoteQuery.albums])
        let albums = try query.ids(RemoteQuery.albums, limit: coversLimit)
        return { _ in try covers(index, albums) }
    }

    private static func covers(_ index: LibraryIndex, _ albums: [Int64]) throws -> RemoteReply {
        let tracks = try index.artTracks(albumIDs: albums)
        let rows = Dictionary(
            try index.rows(ids: Array(Set(tracks.values))).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        var covers: [String: String] = [:]
        for (album, track) in tracks {
            if let row = rows[track], let art = artID(row) { covers[String(album)] = art }
        }
        return RemoteAPI.reply(covers)
    }

    /// The queue's tracks at `window`, of `paths` in play order, as the queue lists them.
    func queueRows(_ paths: [String]) throws -> [TrackLine] {
        let rows = try index().tracks(atPaths: paths)
        return zip(paths, rows).map { path, row in
            row.map(TrackLine.init)
                ?? TrackLine(
                    id: nil,
                    title: URL(fileURLWithPath: path, isDirectory: false)
                        .deletingPathExtension().lastPathComponent, artist: nil, album: nil)
        }
    }

    /// The cover `id` names at size `size`, or nil when no track has that picture now.
    func art(_ id: String, size: String) async throws -> (bytes: Data, type: String)? {
        guard let pixels = Self.artPixels[size] else { return nil }
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
            let track = Int64(parts[0]), track > 0
        else { return nil }
        guard let row = try index().rows(ids: [track]).first, Self.artID(row) == id,
            let art = row.art
        else { return nil }
        let stamp = FileStamp(sizeBytes: row.sizeBytes, modifiedSeconds: row.modifiedSeconds)
        let (thumbnails, read) = (thumbnails, read)
        let bytes = try await artReads.run {
            try thumbnails.encodedThumbnail(
                art, path: row.path, stamp: stamp, pixels: pixels, read: read)
        }
        return (bytes, bytes.starts(with: [0xFF, 0xD8]) ? jpegMIMEType : pngMIMEType)
    }

    /// Play Tracks' or, `queueing`, Queue Tracks' argument as the files to play and the place
    /// to start from. Throws, saying why, for an argument it can't read or tracks it can't find.
    public func files(argument text: String, queueing: Bool) throws -> (urls: [URL], first: Int) {
        guard let tracks = CommandArgument.tracks(text, startAllowed: !queueing) else {
            throw RemoteRefusal(
                "\(text) isn't "
                    + (queueing ? CommandArgument.queueTracksHelp : CommandArgument.playTracksHelp))
        }
        return try files(tracks)
    }

    /// What Play Tracks and Queue Tracks act on, as files in the order they play, and the
    /// position to start from. Throws when the index has none of them, or the album lacks
    /// the track to start from.
    func files(_ tracks: CommandArgument.Tracks) throws -> (urls: [URL], first: Int) {
        let index = try index()
        switch tracks {
        case .tracks(let ids):
            let paths = try index.paths(ids: ids)
            let urls = ids.compactMap { paths[$0] }.map {
                URL(fileURLWithPath: $0, isDirectory: false)
            }
            guard !urls.isEmpty else {
                throw RemoteRefusal("none of those tracks is in the library")
            }
            return (urls, 0)
        case .album(let album, let start):
            let ids = try index.trackIDs(
                Self.trackFilter(genre: nil, artist: nil, album: album, grouped: true),
                sortedBy: .album)
            guard !ids.isEmpty else { throw RemoteRefusal("the library has no album \(album)") }
            return try files(ids, from: start, in: index, of: "album \(album)")
        }
    }

    /// Play List's argument: a track list as `/api/tracks` reads it, by its keys, with
    /// `playFrom=` and the ID of the track to play from, as the files to play and the place to
    /// start. The list is read now, as the window lists it, so it plays whole however long.
    public func files(list text: String) throws -> (urls: [URL], first: Int) {
        let query = RemoteQuery(text)
        try query.only(Self.listKeys.union([RemoteQuery.start]))
        guard let start = try query.id(RemoteQuery.start) else {
            throw RemoteRefusal("playFrom must name the track to play from")
        }
        let list = try Self.list(query, grouped: groupByAlbumArtist)
        let index = try index()
        let ids = try index.trackIDs(list.filter, sortedBy: list.column, ascending: list.ascending)
        return try files(ids, from: start, in: index, of: "the list")
    }

    /// `ids`' files in order, from `start` when given, which must be one of them; an ID whose
    /// file is gone is left out.
    private func files(_ ids: [Int64], from start: Int64?, in index: LibraryIndex, of list: String)
        throws -> (urls: [URL], first: Int)
    {
        var first = 0
        if let start {
            guard let found = ids.firstIndex(of: start) else {
                throw RemoteRefusal("track \(start) isn't in \(list) now; read it again")
            }
            first = found
        }
        let paths = try index.paths(ids: ids)
        let kept = ids.indices.filter { paths[ids[$0]] != nil }
        guard !kept.isEmpty else {
            throw RemoteRefusal("none of \(list)'s tracks is in the library")
        }
        return (
            kept.map { URL(fileURLWithPath: paths[ids[$0]]!, isDirectory: false) },
            kept.firstIndex { $0 >= first } ?? 0
        )
    }
}

/// A list of genres, artists or albums: `[id, name]`, or `[id, name, artist]` for albums.
struct EntryList: Encodable {
    var rows: [EntryLine]

    init(_ entries: [BrowserEntry], albums: Bool) {
        rows = entries.map { EntryLine(entry: $0, album: albums) }
    }
}

struct EntryLine: Encodable {
    var entry: BrowserEntry
    var album: Bool

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(entry.id)
        try container.encode(entry.name)
        if album { try container.encode(entry.artist) }
    }
}

/// A track as a list row: `[id, title, artist, album]`, the ID null for a queued file the index
/// doesn't hold.
struct TrackLine: Encodable, Equatable {
    var id: Int64?
    var title: String
    var artist: String?
    var album: String?

    init(id: Int64?, title: String, artist: String?, album: String?) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
    }

    init(_ name: TrackName) {
        self.init(id: name.id, title: name.title, artist: name.artist, album: name.album)
    }

    init(_ row: TrackRow) {
        self.init(id: row.id, title: row.title, artist: row.artist, album: row.album)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(id)
        try container.encode(title)
        try container.encode(artist)
        try container.encode(album)
    }
}

/// One range of a track list, and how long the whole list is.
struct TrackRange: Encodable {
    var total: Int
    var offset: Int
    /// The library's tag when it was read: a page holding ranges of another starts over.
    var stamp: String
    var rows: [TrackLine]
}

/// What a search found of each kind.
struct Found: Encodable {
    var artists: [EntryLine]
    var albums: [EntryLine]
    var tracks: [TrackLine]
}
