import Foundation
import Log

private let logger = moduleLogger()

/// Where playback and the window were at quit, which every Mac reading the config file puts
/// back at launch, paused (ADR 0095). Tracks are shared names: a sync path, or an absolute path
/// for a folder stored by path. Sources are `BrowserSource` texts with a playlist named by its
/// sync ID, null for the library. Nothing saved is null in the file.
///
/// A value of another shape, such as one a Mac on another build wrote, reads as nothing and is
/// logged, rather than being a problem that blocks the file: it's state the app writes, and
/// the next save replaces it.
public struct ResumePoint: SettingValue {
    /// The track loaded, nil when none was.
    public var track: String?
    /// How far into `track`.
    public var seconds: Double
    /// The source `track` was played from, whose list is its queue.
    public var from: String?
    /// The source the window showed.
    public var source: String?
    /// The selected track.
    public var selected: String?
    /// The first visible track.
    public var top: String?

    public init(
        track: String? = nil, seconds: Double = 0, from: String? = nil, source: String? = nil,
        selected: String? = nil, top: String? = nil
    ) {
        self.track = track
        self.seconds = seconds
        self.from = from
        self.source = source
        self.selected = selected
        self.top = top
    }

    /// Nothing saved.
    public var isEmpty: Bool { self == ResumePoint() }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case track, seconds, from, source, selected, top
    }

    public init(from decoder: any Decoder) throws {
        self.init()
        if try decoder.singleValueContainer().decodeNil() { return }
        do {
            let container = try strictContainer(decoder, CodingKeys.self)
            let seconds = try container.decode(Double.self, forKey: .seconds)
            guard seconds.isFinite, seconds >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .seconds, in: container,
                    debugDescription: "\(seconds) isn't a place in a track")
            }
            self.init(
                track: try container.decode(String?.self, forKey: .track), seconds: seconds,
                from: try container.decode(String?.self, forKey: .from),
                source: try container.decode(String?.self, forKey: .source),
                selected: try container.decode(String?.self, forKey: .selected),
                top: try container.decode(String?.self, forKey: .top))
        } catch {
            logger.error(
                "the saved play state doesn't match this build; starting without it: \(error)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if isEmpty {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(track, forKey: .track)
        try container.encode(seconds, forKey: .seconds)
        try container.encode(from, forKey: .from)
        try container.encode(source, forKey: .source)
        try container.encode(selected, forKey: .selected)
        try container.encode(top, forKey: .top)
    }

    public static var typeName: String {
        "a play state (track, seconds, from, source, selected, top) or null"
    }
    public static var kind: SettingKind { .windowState }
}
