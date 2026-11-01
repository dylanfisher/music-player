import Foundation

/// Another player's library, read for an import (ADR 0033): its tracks, one per path, its
/// playlists, and what couldn't be read. Nothing here has touched this app's library yet.
public struct PlayerLibrary: Equatable, Sendable {
    public enum Player: String, CaseIterable, Sendable {
        case swinsian
        case iTunes

        /// "Swinsian", "iTunes or Music".
        public var title: String {
            switch self {
            case .swinsian: "Swinsian"
            case .iTunes: "iTunes or Music"
            }
        }
    }

    public var player: Player
    /// The file read.
    public var source: String
    /// One per path, compared in NFC, in the order first read.
    public var tracks: [PlayerTrack] = []
    public var playlists: [PlayerPlaylist] = []
    /// Rows naming a path an earlier row named, merged into that track.
    public var mergedRows = 0
    /// Tracks with no file, such as streamed or cloud ones, which nothing can match.
    public var tracksWithoutFiles = 0
    /// The master playlist, built-in ones and folders, which aren't the user's own lists.
    public var builtInPlaylists = 0
    public var problems: [PlayerLibraryProblem] = []
    public var unlistedProblemCount = 0

    /// Index into `tracks` by path in NFC.
    private var trackByPath: [String: Int] = [:]

    /// Past any real library: the owner's is 43k tracks.
    static let maximumTracks = 1_000_000
    static let maximumPlaylists = 10_000
    /// Entries of every playlist together.
    static let maximumEntries = 2_000_000
    static let maximumRules = 100
    /// Four times macOS's `PATH_MAX`, as for a playlist file's line.
    static let maximumPathBytes = 4096
    static let maximumNameBytes = 1024

    /// Reads `player`'s library file at `url`.
    public static func read(_ player: Player, at url: URL) throws -> PlayerLibrary {
        switch player {
        case .swinsian: try PlayerLibrary(swinsianAt: url)
        case .iTunes: try PlayerLibrary(iTunesXMLAt: url)
        }
    }

    init(player: Player, source: String) {
        self.player = player
        self.source = source
    }

    public static func == (lhs: PlayerLibrary, rhs: PlayerLibrary) -> Bool {
        lhs.player == rhs.player && lhs.source == rhs.source && lhs.tracks == rhs.tracks
            && lhs.playlists == rhs.playlists && lhs.mergedRows == rhs.mergedRows
            && lhs.tracksWithoutFiles == rhs.tracksWithoutFiles
            && lhs.builtInPlaylists == rhs.builtInPlaylists && lhs.problems == rhs.problems
            && lhs.unlistedProblemCount == rhs.unlistedProblemCount
    }

    /// Adds `track`, or merges it into the track already read for its path, and returns the
    /// path the library keeps for it, which playlists name.
    mutating func add(_ track: PlayerTrack) -> String {
        let key = track.path.precomposedStringWithCanonicalMapping
        if let index = trackByPath[key] {
            tracks[index].merge(track)
            mergedRows += 1
            return tracks[index].path
        }
        trackByPath[key] = tracks.count
        tracks.append(track)
        return track.path
    }

    mutating func note(_ problem: PlayerLibraryProblem) {
        if problems.count < PlaylistFile.maximumProblems {
            problems.append(problem)
        } else {
            unlistedProblemCount += 1
        }
    }

    /// `text` when it's at most `maximumBytes` of UTF-8 with no NUL, else nil after noting why.
    mutating func checkedText(_ text: String, _ item: String, maximumBytes: Int) -> String? {
        if text.utf8.count > maximumBytes {
            note(PlayerLibraryProblem(item, .tooLong(maximumBytes)))
            return nil
        }
        if text.unicodeScalars.contains("\0") {
            note(PlayerLibraryProblem(item, .holdsNUL))
            return nil
        }
        return text
    }

    /// `seconds` since 1970 when it's from 1970 to a day from now, else nil after noting it.
    mutating func checkedDate(_ seconds: Double, _ item: String, _ field: String, now: Double)
        -> Double?
    {
        guard seconds.isFinite, seconds >= 0, seconds <= now + 86_400 else {
            note(PlayerLibraryProblem(item, .outOfRange(field, "\(seconds)")))
            return nil
        }
        return seconds
    }
}

/// An import that can't go on at all.
enum PlayerImportError: Error, Equatable, CustomStringConvertible {
    /// The tables and columns the reader needs that the database doesn't have (ADR 0033).
    case missingSchema([String])
    case tooLarge(Int, maximum: Int)
    /// The file changed while it was copied, so the copy may be torn.
    case changedWhileCopying(String)
    case unreadable(String)
    /// Not the shape of the file the player writes.
    case notALibrary(String)

    var description: String {
        switch self {
        case .missingSchema(let missing):
            "the database doesn't have what a Swinsian library was assumed to: missing "
                + missing.joined(separator: ", ")
        case .tooLarge(let bytes, let maximum):
            "it's \(bytes) bytes; libraries over \(maximum) bytes aren't read"
        case .changedWhileCopying(let path):
            "\(path) changed while it was copied; quit Swinsian and import again"
        case .unreadable(let detail): "couldn't be read: \(detail)"
        case .notALibrary(let detail): "it isn't a library this app reads: \(detail)"
        }
    }
}
