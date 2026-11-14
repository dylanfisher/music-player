import StrictKeys

/// The library's albums connected to one of them, the seed, grouped by what they share with it,
/// from `POST /v1/threads` (`docs/api.md` there, section Threads; ADR 0208). Its albums and
/// threads are Rediscover's types: an album without `score` and `reasons`, a thread of one
/// album or more. A `kind` this player doesn't know fails the reply, as Rediscover's does.
package struct AlbumThreads: Equatable, Sendable, Decodable {
    package var seed: RediscoverDay.Album
    /// When the threads were computed, in Unix seconds.
    package var computedAt: Int
    /// Every album in a thread, each once, the seed never: the most threads first.
    package var albums: [RediscoverDay.Album]
    /// What the albums share with the seed, strongest first, at most 12.
    package var threads: [RediscoverDay.Thread]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ok, seed
        case computedAt = "computed_at"
        case albums, threads
    }
}

extension AlbumThreads {
    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        seed = try container.decode(UnscoredAlbum.self, forKey: .seed).album
        computedAt = try container.decode(Int.self, forKey: .computedAt)
        albums = try container.decode([UnscoredAlbum].self, forKey: .albums).map(\.album)
        threads = try container.decode([RediscoverDay.Thread].self, forKey: .threads)
    }
}

/// An album of the reply, decoded without `score` and `reasons`.
private struct UnscoredAlbum: Decodable {
    var album: RediscoverDay.Album

    init(from decoder: any Decoder) throws {
        album = try RediscoverDay.Album(from: decoder, scored: false)
    }
}
