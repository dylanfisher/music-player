import DisplayText
import Foundation
import Playback
import Settings
import StrictKeys

/// What `music-player status` reports. Its JSON, from `status --json`, is a stable shape for
/// scripts: every key is always there, `null` when it has no value, and keys are only ever
/// added (ADR 0036).
public struct ScriptStatus: Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case stopped, playing, paused
    }

    /// The track playing or paused, or the one play starts.
    public struct Track: Equatable, Sendable {
        public var path: String
        /// Nil for a file the library no longer holds.
        public var title: String?
        public var artist: String?
        public var album: String?
        public var albumArtist: String?
        public var durationSeconds: Double?

        public init(
            path: String, title: String?, artist: String?, album: String?, albumArtist: String?,
            durationSeconds: Double?
        ) {
            self.path = path
            self.title = title
            self.artist = artist
            self.album = album
            self.albumArtist = albumArtist
            self.durationSeconds = durationSeconds
        }
    }

    public var state: State
    public var track: Track?
    public var positionSeconds: Double?
    /// One-based, in the order the queue plays.
    var queuePosition: Int?
    var queueLength: Int
    public var shuffle: Bool
    public var repeatMode: RepeatMode

    /// `track` is the current track's tags, looked up by the caller.
    public init(_ playback: PlaybackState, positionSeconds: Double?, track: Track?) {
        state =
            switch playback.status {
            case .stopped: .stopped
            case .playing: .playing
            case .paused: .paused
            }
        self.track = track
        self.positionSeconds = playback.status == .stopped ? nil : positionSeconds
        queuePosition = playback.currentIndex.flatMap { index in
            playback.order.firstIndex(of: index).map { $0 + 1 }
        }
        queueLength = playback.queue.count
        shuffle = playback.shuffle
        repeatMode = playback.repeatMode
    }

    /// What `status --json` prints: one line, keys sorted.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// The lines `status` prints without `--json`, each escaped for the terminal, since tags
    /// are hostile text.
    public var text: String {
        var lines = [state.rawValue.capitalized]
        if let track {
            lines.append(track.title ?? (track.path as NSString).lastPathComponent)
            if let artist = track.artist { lines.append("by \(artist)") }
            if let album = track.album { lines.append("on \(album)") }
        }
        var place: [String] = []
        if let positionSeconds {
            let total = track?.durationSeconds.map { " of \(clock($0))" } ?? ""
            place.append("\(clock(positionSeconds))\(total)")
        }
        if let queuePosition { place.append("track \(queuePosition) of \(queueLength)") }
        place.append("shuffle \(shuffle ? "on" : "off")")
        place.append("repeat \(repeatMode.rawValue)")
        lines.append(place.joined(separator: ", "))
        return lines.map(terminalSafe).joined(separator: "\n")
    }
}

/// Minutes and seconds, "4:05".
private func clock(_ seconds: Double) -> String {
    let whole = Int(seconds.rounded(.down))
    return "\(whole / 60):" + String(format: "%02d", whole % 60)
}

extension ScriptStatus: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case state, track, positionSeconds, queuePosition, queueLength, shuffle
        case repeatMode = "repeat"
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        state = try container.decode(State.self, forKey: .state)
        track = try container.decode(Track?.self, forKey: .track)
        positionSeconds = try container.decode(Double?.self, forKey: .positionSeconds)
        queuePosition = try container.decode(Int?.self, forKey: .queuePosition)
        queueLength = try container.decode(Int.self, forKey: .queueLength)
        shuffle = try container.decode(Bool.self, forKey: .shuffle)
        let mode = try container.decode(String.self, forKey: .repeatMode)
        guard let repeatMode = RepeatMode(rawValue: mode) else {
            throw DecodingError.dataCorruptedError(
                forKey: .repeatMode, in: container, debugDescription: "unknown repeat \(mode)")
        }
        self.repeatMode = repeatMode
    }

    /// Writes `null` for a missing value rather than leaving the key out, so the shape is fixed.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(track, forKey: .track)
        try container.encode(positionSeconds, forKey: .positionSeconds)
        try container.encode(queuePosition, forKey: .queuePosition)
        try container.encode(queueLength, forKey: .queueLength)
        try container.encode(shuffle, forKey: .shuffle)
        try container.encode(repeatMode.rawValue, forKey: .repeatMode)
    }
}

extension ScriptStatus.Track: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case path, title, artist, album, albumArtist, durationSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        title = try container.decode(String?.self, forKey: .title)
        artist = try container.decode(String?.self, forKey: .artist)
        album = try container.decode(String?.self, forKey: .album)
        albumArtist = try container.decode(String?.self, forKey: .albumArtist)
        durationSeconds = try container.decode(Double?.self, forKey: .durationSeconds)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
        try container.encode(albumArtist, forKey: .albumArtist)
        try container.encode(durationSeconds, forKey: .durationSeconds)
    }
}
