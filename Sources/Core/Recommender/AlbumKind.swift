/// Which Discogs number an id is, a master's or a release's: Discogs numbers the two apart, so a
/// recommended album and a mark on it name both.
package enum AlbumKind: String, Equatable, Hashable, Sendable, Codable {
    case master, release
}
