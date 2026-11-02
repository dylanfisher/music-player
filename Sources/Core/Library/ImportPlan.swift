import Foundation
import Settings

/// What importing another player's library would change, or did (ADR 0033): the preview's
/// counts, and the writes behind them.
public struct ImportPlan: Equatable, Sendable {
    public var library: PlayerLibrary
    public var prefix: PathPrefix?
    /// Tracks the index holds that the library names.
    public var matched = 0
    /// Paths the index holds no track for, after the prefix, in the library's order, that the
    /// scanner would read.
    public var unmatched: [String] = []
    /// Paths the index holds no track for in a format the scanner doesn't read, such as DSF
    /// before phase 12, which no prefix or folder can match.
    public var unreadFormat: [String] = []
    /// Source rows merged into another for the same track: the library's, plus paths that
    /// reached one track only after the prefix or the lookup in NFC.
    public var mergedRows = 0
    public var playsAdded = 0
    public var tracksGainingPlays = 0
    public var skipsAdded = 0
    public var tracksGainingSkips = 0
    /// Tracks whose last played moves later.
    public var lastPlayed = 0
    /// Tracks whose date added moves earlier.
    public var dateAdded = 0
    /// Tracks rated here for the first time.
    public var ratings = 0
    /// Of `ratings`, those that were a half star rounded up.
    public var roundedRatings = 0
    /// Tracks rated differently here, which keep ours.
    public var ratingsKept = 0
    public var loved = 0
    public var playlists: [PlannedPlaylist] = []
    /// Playlists not made because one of the name exists, in the library's order.
    public var existingPlaylists: [String] = []

    var updates: [TrackUpdate] = []

    /// Whether confirming would write anything.
    public var changesSomething: Bool { !updates.isEmpty || !playlists.isEmpty }

    /// The tracks this plan missed under `folder`, at the paths it looked them up by, and no
    /// playlists, whose names an import already made: what Locate… matches again (ADR 0053).
    public func misses(under folder: String) -> PlayerLibrary {
        let missed = Set(unmatched)
        let folder = folder.precomposedStringWithCanonicalMapping
        var found = PlayerLibrary(player: library.player, source: library.source)
        for var track in library.tracks {
            track.path = prefix?.apply(track.path) ?? track.path
            guard missed.contains(track.path),
                isPath(track.path.precomposedStringWithCanonicalMapping, inOrAt: folder)
            else { continue }
            _ = found.add(track)
        }
        return found
    }
}

/// A playlist an import makes.
public struct PlannedPlaylist: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case manual([Int64])
        case smart(SmartRules)
    }

    public var name: String
    public var kind: Kind
    /// Whether it was a smart playlist in the other player, made manual of its tracks.
    public var wasSmart = false
    /// Entries with no track in the index, or no file in the other player.
    public var missing = 0
    /// Entries naming a track already listed, which a playlist holds once (ADR 0018).
    public var repeated = 0
}

/// The writes for one track. Counts are the deltas; the others are the source's values, which
/// the writes compare with ours again, so a change since the plan isn't overwritten.
struct TrackUpdate: Equatable, Sendable {
    var pathID: Int64
    var plays: Int
    var skips: Int
    /// The source's totals, recorded so the next import adds only what grew; nil when they
    /// equal what's recorded.
    var imported: ImportedCounts?
    var lastPlayedSeconds: Double?
    var addedSeconds: Double?
    var rating: Int?
    var loves: Bool

    var writesNothing: Bool {
        plays == 0 && skips == 0 && imported == nil && lastPlayedSeconds == nil
            && addedSeconds == nil && rating == nil && !loves
    }
}

/// A player's play and skip counts for one track at its last import.
struct ImportedCounts: Equatable, Sendable {
    var plays: Int
    var skips: Int
}
