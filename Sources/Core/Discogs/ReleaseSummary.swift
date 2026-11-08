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
    /// The tracks a file can be, as the matcher counts them: headings left out, an index
    /// track's parts each one.
    public var trackCount: Int
}

/// A release as View Release shows it: its summary and its tracklist as Discogs lists it.
public struct ReleaseDetail: Equatable, Sendable {
    /// A row of the tracklist: a track, a heading (no position or length), or an index track
    /// followed by its parts.
    public struct Track: Equatable, Sendable {
        public var position: String
        public var title: String
        public var seconds: Int?
    }

    public var summary: ReleaseSummary
    public var tracks: [Track]
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
            format: formats.map(mediaText).joined(separator: ", "),
            trackCount: ReleaseTracklist.flattenings(tracks)[0].count)
    }

    var detail: ReleaseDetail {
        func row(_ track: CatalogTrack) -> ReleaseDetail.Track {
            ReleaseDetail.Track(
                position: track.position ?? "", title: track.title,
                seconds: ReleaseTracklist.seconds(track))
        }
        return ReleaseDetail(
            summary: summary, tracks: tracks.flatMap { [row($0)] + $0.subTracks.map(row) })
    }
}

/// The release `id` as View Release shows it, from the catalog at `catalog`, read off the
/// calling thread on a connection of its own, else from what `api` has cached; nil when
/// neither has it. With `api`, a missing catalog is no error.
public func releaseDetail(_ id: Int, catalogAt catalog: URL, api: DiscogsAPI? = nil)
    async throws -> ReleaseDetail?
{
    try await releases([id], catalogAt: catalog, api: api).first?.detail
}

/// The summaries of the releases `ids`, in their order, from the catalog at `catalog`, read
/// off the calling thread on a connection of their own, else from what `api` has cached, so
/// a release the API found needs no new request (ADR 0139); an id neither has is left out.
/// With `api`, a missing catalog is no error.
public func releaseSummaries(_ ids: [Int], catalogAt catalog: URL, api: DiscogsAPI? = nil)
    async throws -> [ReleaseSummary]
{
    try await releases(ids, catalogAt: catalog, api: api).map(\.summary)
}

private func releases(_ ids: [Int], catalogAt catalog: URL, api: DiscogsAPI?) async throws
    -> [CatalogRelease]
{
    try await Task.detached(priority: .userInitiated) {
        let opened: Catalog?
        do {
            opened = try Catalog(at: catalog)
        } catch CatalogError.missing where api != nil {
            opened = nil
        }
        var found: [CatalogRelease] = []
        for id in ids {
            if let release = try opened?.release(id: id) {
                found.append(release)
            } else if let release = await api?.cachedRelease(id: id)?.release {
                found.append(release)
            }
        }
        return found
    }.value
}
