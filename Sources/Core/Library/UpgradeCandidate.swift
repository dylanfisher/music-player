/// A lossy library album tagged with one Discogs release, which a lossless download of that
/// release could replace (phase 54): what an upgrade job sends the service as `upgrade`.
package struct UpgradeCandidate: Equatable, Sendable {
    package var albumID: Int64
    package var title: String
    /// The album artist, else the track artist; nil for a compilation without one.
    package var artist: String?
    package var releaseID: Int
    /// The album's files in disc and track order, relative to the share, so they resolve on
    /// any Mac that mounts it and after an index rebuild.
    package var sharePaths: [String]
    /// For the Downloads window: "MP3 320 kbps", the codec and the album's average bit rate.
    package var quality: String
}

/// Codecs whose files an upgrade replaces, as `tracks.codec` stores them.
private let lossyCodecs: Set<String> = ["aac", "mp3"]

extension LibraryIndex {
    /// The albums whose every file is lossy, carries one `DISCOGS_RELEASE_ID` that's a number,
    /// and is in a watched folder on `share`, by album ID. An album with a file anywhere else
    /// isn't one: the service keeps an upgrade's old files by their path on the share.
    package func upgradeCandidates(onShare share: String) throws -> [UpgradeCandidate] {
        let roots = try statement(
            "SELECT inner_path, root FROM \(shareRootsTable) WHERE share = ?"
        ).map(share) { (inner: try $0.text(0), root: try $0.text(1)) }
        let rows = try statement(
            """
            SELECT t.album_id, a.title, ar.name, t.discogs_release_id, f.path, t.codec,
                f.size_bytes, ifnull(t.art_byte_count, 0), t.length_frames, t.sample_rate_hz
            FROM tracks t JOIN albums a ON a.id = t.album_id JOIN files f ON f.id = t.file_id
            LEFT JOIN artists ar ON ar.id = a.artist_id
            ORDER BY t.album_id, t.disc_number IS NULL, t.disc_number, t.track_number IS NULL,
                t.track_number, f.path
            """
        ).map { row in
            let rateHz = try row.int(9)
            return (
                album: try row.int64(0), title: try row.text(1), artist: row.optionalText(2),
                release: row.optionalText(3), path: try row.text(4), codec: try row.text(5),
                audioBytes: try row.int(6) - (try row.int(7)),
                seconds: rateHz > 0 ? Double(try row.int(8)) / Double(rateHz) : 0
            )
        }
        var candidates: [UpgradeCandidate] = []
        var start = rows.startIndex
        while start < rows.endIndex {
            let album = rows[start].album
            let end = rows[start...].firstIndex { $0.album != album } ?? rows.endIndex
            let tracks = rows[start..<end]
            start = end
            let releases = Set(tracks.map(\.release))
            guard releases.count == 1,
                let release = releases.first.flatMap({ $0.flatMap(Int.init) }),
                tracks.allSatisfy({ lossyCodecs.contains($0.codec) })
            else { continue }
            let paths = tracks.compactMap { track in
                roots.lazy.compactMap { sharePath(track.path, inner: $0.inner, root: $0.root) }
                    .first
            }
            guard paths.count == tracks.count else { continue }
            let seconds = tracks.map(\.seconds).reduce(0, +)
            let bits = Double(tracks.map(\.audioBytes).reduce(0, +)) * 8
            let kbps = seconds > 0 ? Int((bits / seconds / 1000).rounded()) : 0
            let codecs = Set(tracks.map(\.codec)).sorted().map { $0.uppercased() }
            candidates.append(
                UpgradeCandidate(
                    albumID: album, title: tracks[tracks.startIndex].title,
                    artist: tracks[tracks.startIndex].artist, releaseID: release,
                    sharePaths: paths,
                    quality: codecs.joined(separator: "/") + " \(kbps) kbps"))
        }
        return candidates
    }
}

/// `path` relative to the share, when it's under `root`, the folder `inner` of the share.
private func sharePath(_ path: String, inner: String, root: String) -> String? {
    guard isPath(path, under: root) else { return nil }
    let rest = String(path.dropFirst(stem(root).count + 1))
    return inner.isEmpty ? rest : inner + "/" + rest
}
