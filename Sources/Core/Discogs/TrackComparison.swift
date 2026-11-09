import Library

/// A row of the tagger window's tracklists side by side: a file and the release's track it's
/// mapped to, or either alone.
public struct TrackComparison: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// The titles are the same, as the matcher compares them, and the length agrees where
        /// Discogs has one.
        case matched
        case different
        /// A track no file is mapped to, or a file mapped to no track.
        case missing
    }

    public var fileID: Int64?
    public var fileTitle: String?
    public var fileSeconds: Double?
    /// The track's index in `AlbumMatch.tracks`.
    public var track: Int?
    /// As Discogs writes it: "A1", "CD2-4".
    public var position: String?
    public var releaseTitle: String?
    public var releaseSeconds: Int?
    public var state: State
}

extension AlbumMatch {
    /// The release's tracks in order, each beside the file mapped to it, then the files mapped
    /// to none, those in `leftOut`, which the user left out of the match, last.
    public func comparison(of album: DiscogsAlbum, leftOut: Set<Int64> = []) -> [TrackComparison] {
        let all = rows(of: album)
        return all.filter { !($0.fileID.map(leftOut.contains) ?? false) }
            + all.filter { $0.fileID.map(leftOut.contains) ?? false }
    }

    private func rows(of album: DiscogsAlbum) -> [TrackComparison] {
        let files = Dictionary(uniqueKeysWithValues: album.tracks.map { ($0.fileID, $0) })
        let byTrack = Dictionary(mapping.map { ($0.value, $0.key) }, uniquingKeysWith: min)
        var rows = tracks.enumerated().map { index, track in
            let file = byTrack[index].flatMap { files[$0] }
            return TrackComparison(
                fileID: file?.fileID, fileTitle: file?.title, fileSeconds: file?.seconds,
                track: index, position: track.position, releaseTitle: track.title,
                releaseSeconds: track.durationSeconds,
                state: file.map { Self.state($0, track) } ?? .missing)
        }
        for file in album.tracks where mapping[file.fileID] == nil {
            rows.append(
                TrackComparison(
                    fileID: file.fileID, fileTitle: file.title, fileSeconds: file.seconds,
                    state: .missing))
        }
        return rows
    }

    private static func state(_ file: DiscogsAlbum.Track, _ track: CatalogTrack)
        -> TrackComparison
        .State
    {
        let similarity = TitleSimilarity([file.title]).similarities(to: track.title)[0]
        let lengthAgrees = track.durationSeconds.map { ReleaseScore.agrees(file.seconds, $0) }
        return similarity >= MatchThreshold.sameTitle && lengthAgrees != false
            ? .matched : .different
    }

    /// Maps the file `fileID` to the track at `track` in `tracks`, as a row dragged in the
    /// window does; the file that had that track takes the moved file's old one, or none.
    /// Nil maps the file to no track.
    public mutating func assign(_ fileID: Int64, to track: Int?) {
        let old = mapping[fileID]
        if let track, let other = mapping.first(where: { $0.value == track })?.key,
            other != fileID
        {
            mapping[other] = old
        }
        mapping[fileID] = track
    }
}
