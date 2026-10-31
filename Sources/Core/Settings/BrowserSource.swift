/// What the sidebar shows instead of the whole library: a watched folder, a playlist or
/// History. Saved as one string: the folder's path, `playlist:<id>`, or `history`.
public enum BrowserSource: SettingValue, Hashable {
    case folder(String)
    /// A playlist's ID, which an index rebuild keeps (ADR 0018).
    case playlist(Int64)
    /// Every track played, most recent first.
    case history

    private static let playlistPrefix = "playlist:"
    private static let historyText = "history"

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        if text.hasPrefix("/") {
            self = .folder(text)
        } else if text == Self.historyText {
            self = .history
        } else if text.hasPrefix(Self.playlistPrefix),
            let id = Int64(text.dropFirst(Self.playlistPrefix.count))
        {
            self = .playlist(id)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "\"\(text)\" isn't a path, playlist or history")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .folder(let path): try container.encode(path)
        case .playlist(let id): try container.encode(Self.playlistPrefix + String(id))
        case .history: try container.encode(Self.historyText)
        }
    }

    public static var typeName: String {
        "a folder's path, \"\(playlistPrefix)<id>\" or \"\(historyText)\""
    }
    public static var kind: SettingKind { .windowState }
}
