/// Where each window other than the main one was left, by the name it keeps its frame under
/// (ADR 0158): `{"Settings": {"x": …, "y": …, "width": …, "height": …}}`.
public struct WindowFrames: SettingValue {
    public var frames: [String: WindowFrame]

    public init(_ frames: [String: WindowFrame] = [:]) { self.frames = frames }

    public init(from decoder: any Decoder) throws {
        frames = try decoder.singleValueContainer().decode([String: WindowFrame].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(frames)
    }

    public static var typeName: String { "window frames by window name" }
    public static var kind: SettingKind { .windowState }

    public func problem() -> String? {
        for name in frames.keys.sorted() {
            if let problem = frames[name]?.problem() { return "\(name): \(problem)" }
        }
        return nil
    }
}
