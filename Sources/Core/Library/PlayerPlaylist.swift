/// A playlist of another player's.
public struct PlayerPlaylist: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case manual
        /// Rules that each map onto ours.
        case smart(SmartRules)
        /// A smart playlist with rules that don't map, each with why; it isn't imported.
        case unmapped([String])
        /// An iTunes smart playlist, whose rules are a private format: its tracks as listed.
        case smartAsManual
    }

    public var name: String
    public var kind: Kind
    /// The tracks, by the path `PlayerLibrary.tracks` holds, in order; empty for `.smart`.
    public var paths: [String] = []
    /// Entries naming a track the library has no file for.
    var entriesWithoutFiles = 0
}
