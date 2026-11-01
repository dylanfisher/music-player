/// What the sidebar shows instead of the whole library: a folder, a playlist, History, the play
/// timeline or a health check. Saved as one string: the folder's path, `playlist:<id>`,
/// `history`, `timeline` or `health:<check>`.
public enum BrowserSource: SettingValue, Hashable {
    case folder(String)
    /// A playlist's ID, which an index rebuild keeps (ADR 0018).
    case playlist(Int64)
    /// Every track played, most recent first.
    case history
    /// Every play, newest first, a track as often as it was played (ADR 0022).
    case timeline
    /// The tracks a check of the health report found (ADR 0034).
    case health(HealthCheck)

    private static let playlistPrefix = "playlist:"
    private static let historyText = "history"
    private static let timelineText = "timeline"
    private static let healthPrefix = "health:"

    /// The source as one string, which the state file saves and the palette keys a playlist
    /// by.
    public var text: String {
        switch self {
        case .folder(let path): path
        case .playlist(let id): Self.playlistPrefix + String(id)
        case .history: Self.historyText
        case .timeline: Self.timelineText
        case .health(let check): Self.healthPrefix + check.rawValue
        }
    }

    /// Reads `text`; nil for a string that isn't one of the sources.
    public init?(text: String) {
        if text.hasPrefix("/") {
            self = .folder(text)
        } else if text == Self.historyText {
            self = .history
        } else if text == Self.timelineText {
            self = .timeline
        } else if text.hasPrefix(Self.playlistPrefix),
            let id = Int64(text.dropFirst(Self.playlistPrefix.count))
        {
            self = .playlist(id)
        } else if text.hasPrefix(Self.healthPrefix),
            let check = HealthCheck(rawValue: String(text.dropFirst(Self.healthPrefix.count)))
        {
            self = .health(check)
        } else {
            return nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let source = BrowserSource(text: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\"\(text)\" isn't \(BrowserSource.typeName)")
        }
        self = source
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    public static var typeName: String {
        "a folder's path, \"\(playlistPrefix)<id>\", \"\(historyText)\", \"\(timelineText)\" or"
            + " \"\(healthPrefix)<check>\""
    }
    public static var kind: SettingKind { .windowState }
}
