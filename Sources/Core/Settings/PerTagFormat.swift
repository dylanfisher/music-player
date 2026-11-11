import Metadata
import StrictKeys

/// A value that can differ between tag formats, as YATE spells some keys one way in FLAC and
/// another in MP4 and ID3 (ADR 0128). In JSON it is the value, when every format has the same
/// one, or an object with all three: `{"vorbis": …, "mp4": …, "id3": …}`.
public struct PerTagFormat<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var vorbis: Value
    public var mp4: Value
    public var id3: Value

    init(vorbis: Value, mp4: Value, id3: Value) {
        self.vorbis = vorbis
        self.mp4 = mp4
        self.id3 = id3
    }

    /// The same value in every format.
    public init(_ value: Value) { self.init(vorbis: value, mp4: value, id3: value) }

    /// Whether every format has the same value, which JSON writes as the value alone.
    public var isUniform: Bool { vorbis == mp4 && mp4 == id3 }

    public subscript(format: TagFormat) -> Value {
        get {
            switch format {
            case .vorbis: vorbis
            case .mp4: mp4
            case .id3: id3
            }
        }
        set {
            switch format {
            case .vorbis: vorbis = newValue
            case .mp4: mp4 = newValue
            case .id3: id3 = newValue
            }
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case vorbis, mp4, id3
    }

    public init(from decoder: any Decoder) throws {
        // Not a single value means the per-format object, whose decode below throws if it isn't.
        if let value = try? decoder.singleValueContainer().decode(Value.self) {
            self.init(value)
            return
        }
        let container = try strictContainer(decoder, CodingKeys.self)
        self.init(
            vorbis: try container.decode(Value.self, forKey: .vorbis),
            mp4: try container.decode(Value.self, forKey: .mp4),
            id3: try container.decode(Value.self, forKey: .id3))
    }

    public func encode(to encoder: any Encoder) throws {
        if isUniform {
            var container = encoder.singleValueContainer()
            try container.encode(vorbis)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vorbis, forKey: .vorbis)
        try container.encode(mp4, forKey: .mp4)
        try container.encode(id3, forKey: .id3)
    }
}
