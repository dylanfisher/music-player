/// What `GET /api/state` and each event say (ADR 0214): what's playing and where, with the time
/// the position was read so the page advances its bar itself, the queue's change stamp, the
/// volumes, the output, and the receiver while receiver control is on. A key whose value is
/// unknown is left out.
public struct RemoteState: Encodable, Equatable, Sendable {
    public enum Playing: String, Encodable, Sendable {
        case stopped, playing, paused
    }

    public struct Track: Encodable, Equatable, Sendable {
        public var id: Int64
        public var albumID: Int64?
        public var title: String
        public var artist: String?
        public var album: String?
        public var durationSeconds: Double?
        /// The cover's ID in `/api/art`, as `RemoteLibrary.artID` names it; nil for none.
        public var art: String?

        public init(
            id: Int64, albumID: Int64?, title: String, artist: String?, album: String?,
            durationSeconds: Double?, art: String? = nil
        ) {
            self.id = id
            self.albumID = albumID
            self.title = title
            self.artist = artist
            self.album = album
            self.durationSeconds = durationSeconds
            self.art = art
        }
    }

    public struct Output: Encodable, Equatable, Sendable {
        /// `OutputChoice.text`, which Choose Output takes back.
        public var choice: String
        public var name: String

        public init(choice: String, name: String) {
            self.choice = choice
            self.name = name
        }
    }

    public struct Receiver: Encodable, Equatable, Sendable {
        public var isOn: Bool?
        public var volumeDecibels: Double?
        public var isMuted: Bool?
        /// The input's raw value, as `inputs` names it.
        public var input: String?
        /// Every input the page's menu offers, with the command that switches to it.
        public var inputs: [Input]
        /// The ends of the page's slider, the signal path slider's, so neither goes higher.
        public var volumeFloorDecibels: Double?
        public var volumeCeilingDecibels: Double?

        public struct Input: Encodable, Equatable, Sendable {
            public var value: String
            public var title: String
            public var command: String
        }

        public init(
            isOn: Bool?, volumeDecibels: Double?, isMuted: Bool?, input: String?,
            inputs: [Input] = [], volumeRangeDecibels: ClosedRange<Double>? = nil
        ) {
            self.isOn = isOn
            self.volumeDecibels = volumeDecibels
            self.isMuted = isMuted
            self.input = input
            self.inputs = inputs
            volumeFloorDecibels = volumeRangeDecibels?.lowerBound
            volumeCeilingDecibels = volumeRangeDecibels?.upperBound
        }
    }

    public var instance: String
    public var name: String
    public var state: Playing
    /// Nil for nothing loaded, or a file the library no longer holds.
    public var track: Track?
    public var positionSeconds: Double?
    /// Seconds since 1970 on this Mac's clock when the state was read, `positionSeconds` with
    /// it, so the page compares `lastPlayedAt` against this Mac's own clock, not the phone's.
    public var now: Double
    /// Changes whenever the queue's tracks or order do.
    public var queueStamp: Int
    public var queueLength: Int
    /// One-based, in the order the queue plays.
    public var queuePosition: Int?
    public var shuffle: Bool
    /// `RepeatMode`'s raw value.
    public var repeatMode: String
    /// Nil while the app's volume is fixed: Digital Volume off, or a renderer playing.
    public var volumeDecibels: Double?
    /// The lowest the app's volume goes, for the page's slider; nil with `volumeDecibels`.
    public var volumeFloorDecibels: Double?
    public var output: Output?
    public var receiver: Receiver?
    /// Seconds since 1970 when this Mac last started playing, for the page to choose among
    /// Macs that are.
    public var lastPlayedAt: Double?

    public init(
        instance: String, name: String, state: Playing, track: Track?, positionSeconds: Double?,
        now: Double, queueStamp: Int, queueLength: Int, queuePosition: Int?,
        shuffle: Bool, repeatMode: String, volumeDecibels: Double?,
        volumeFloorDecibels: Double? = nil, output: Output?, receiver: Receiver?,
        lastPlayedAt: Double?
    ) {
        self.instance = instance
        self.name = name
        self.state = state
        self.track = track
        self.positionSeconds = positionSeconds
        self.now = now
        self.queueStamp = queueStamp
        self.queueLength = queueLength
        self.queuePosition = queuePosition
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.volumeDecibels = volumeDecibels
        self.volumeFloorDecibels = volumeDecibels == nil ? nil : volumeFloorDecibels
        self.output = output
        self.receiver = receiver
        self.lastPlayedAt = lastPlayedAt
    }

    /// How far the position may drift from where `previous` puts it before it's news: a seek,
    /// or a stall, rather than playback going on.
    static let driftSeconds = 1.0

    /// Whether this says anything the page couldn't work out from `previous`: any field but the
    /// position changed, or the position isn't where playing on from `previous` puts it.
    func isNews(after previous: RemoteState) -> Bool {
        var same = self
        same.positionSeconds = previous.positionSeconds
        same.now = previous.now
        guard same == previous else { return true }
        switch (previous.positionSeconds, positionSeconds) {
        case (nil, nil): return false
        case (let before?, let now?):
            let expected =
                before + (state == .playing ? self.now - previous.now : 0)
            return abs(now - expected) > Self.driftSeconds
        default: return true
        }
    }
}

/// The queue as `/api/queue` reads it: the change stamp the state carries, each file's path in
/// the order it plays, and the current track's place in that order.
public struct RemoteQueue: Sendable {
    public var stamp: Int
    public var paths: [String]
    public var position: Int?

    public init(stamp: Int, paths: [String], position: Int?) {
        self.stamp = stamp
        self.paths = paths
        self.position = position
    }
}
