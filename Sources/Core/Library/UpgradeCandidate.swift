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
    /// The album's average bit rate, as `quality` shows it.
    var kbps = 0
    /// Its tracks' play counts, summed, as the track table shows them.
    var plays = 0
    /// Half or more of its tracks are liked, or its rated tracks average 4 stars or more.
    var boosted = false
}

/// Codecs whose files an upgrade replaces, as `tracks.codec` stores them.
let lossyCodecs: Set<String> = ["aac", "mp3"]

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
                f.size_bytes, ifnull(t.art_byte_count, 0), t.length_frames, t.sample_rate_hz,
                max(0, ifnull(p.play_count, 0)), lv.path_id IS NOT NULL, r.rating
            FROM tracks t JOIN albums a ON a.id = t.album_id JOIN files f ON f.id = t.file_id
            LEFT JOIN artists ar ON ar.id = a.artist_id
            LEFT JOIN plays p ON p.path_id = t.file_id
            LEFT JOIN \(lovedTable) lv ON lv.path_id = t.file_id
            LEFT JOIN ratings r ON r.path_id = t.file_id
            ORDER BY t.album_id, t.disc_number IS NULL, t.disc_number, t.track_number IS NULL,
                t.track_number, f.path
            """
        ).map { row in
            let rateHz = try row.int(9)
            return (
                album: try row.int64(0), title: try row.text(1), artist: row.optionalText(2),
                release: row.optionalText(3), path: try row.text(4), codec: try row.text(5),
                audioBytes: try row.int(6) - (try row.int(7)),
                seconds: rateHz > 0 ? Double(try row.int(8)) / Double(rateHz) : 0,
                plays: try row.int(10), liked: try row.int(11) == 1, stars: row.optionalInt(12)
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
            let kbps = averageKbps(
                audioBytes: tracks.map(\.audioBytes).reduce(0, +),
                seconds: tracks.map(\.seconds).reduce(0, +))
            let stars = tracks.compactMap(\.stars)
            candidates.append(
                UpgradeCandidate(
                    albumID: album, title: tracks[tracks.startIndex].title,
                    artist: tracks[tracks.startIndex].artist, releaseID: release,
                    sharePaths: paths,
                    quality: formatName(tracks.map(\.codec)) + " \(kbps) kbps", kbps: kbps,
                    plays: tracks.map(\.plays).reduce(0, +),
                    boosted: tracks.filter(\.liked).count * 2 >= tracks.count
                        || (!stars.isEmpty
                            && stars.reduce(0, +) >= UpgradeCandidate.boostStars * stars.count)
                ))
        }
        return candidates
    }
}

/// An album's average bit rate, in kilobits a second, from its tracks' audio bytes, without
/// their art, and their length; 0 for no length.
func averageKbps(audioBytes: Int, seconds: Double) -> Int {
    seconds > 0 ? Int((Double(audioBytes) * 8 / seconds / 1000).rounded()) : 0
}

/// "MP3", or "AAC/MP3" for an album of both: `codecs`, as `tracks.codec` stores them, once
/// each.
func formatName(_ codecs: [String]) -> String {
    Set(codecs).sorted().map { $0.uppercased() }.joined(separator: "/")
}

/// `path` relative to the share, when it's under `root`, the folder `inner` of the share.
private func sharePath(_ path: String, inner: String, root: String) -> String? {
    guard isPath(path, under: root) else { return nil }
    let rest = String(path.dropFirst(stem(root).count + 1))
    return inner.isEmpty ? rest : inner + "/" + rest
}
