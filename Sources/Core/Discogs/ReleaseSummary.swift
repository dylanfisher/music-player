import Foundation
import Settings

/// A release as the tagger window lists it: the chosen release's header, and a row of Other
/// Releases… with the columns its filters search.
public struct ReleaseSummary: Equatable, Sendable {
    public var id: Int
    /// Canonical names with Discogs's join words, "(2)" dropped.
    public var artist: String
    public var title: String
    /// Every label, joined with " & ", as YATE writes `LABEL`.
    public var label: String
    /// The first label's, as `CATALOGNUMBER` holds it.
    public var catalogNumber: String
    public var country: String
    public var year: String
    /// Each format as `MEDIA` holds it, "CD (Album,Remastered)", joined with ", ".
    public var format: String
}

extension CatalogRelease {
    public var summary: ReleaseSummary {
        let format = DiscogsFieldFormat(join: ", ", suffixes: .drop)
        return ReleaseSummary(
            id: id,
            artist: MappedValue.artists(artists).text(format, tagFormat: .vorbis) ?? "",
            title: title,
            label: labels.map(\.name).joined(separator: " & "),
            catalogNumber: labels.first?.catalogNumber ?? "",
            country: country ?? "", year: released.map { String($0.prefix(4)) } ?? "",
            format: formats.map(mediaText).joined(separator: ", "))
    }
}

/// The summaries of the releases `ids` in the catalog at `catalog`, in their order, read off
/// the calling thread on a connection of their own; an id the catalog lacks is left out.
public func releaseSummaries(_ ids: [Int], catalogAt catalog: URL) async throws
    -> [ReleaseSummary]
{
    try await Task.detached(priority: .userInitiated) {
        let opened = try Catalog(at: catalog)
        return try ids.compactMap { try opened.release(id: $0)?.summary }
    }.value
}
