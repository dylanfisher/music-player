/// What the sidebar shows instead of the whole library: a playlist, History, the play timeline,
/// its plays in a span, a health check or Listening Stats. Saved as one string:
/// `playlist:<id>`, `history`, `timeline`, `plays:<start>-<end>`, `health:<check>` or
/// `stats:<period>`.
public enum BrowserSource: SettingValue, Hashable {
    /// A playlist's ID, which an index rebuild keeps (ADR 0018).
    case playlist(Int64)
    /// Every track with a recorded play, most recent first.
    case history
    /// Every play, newest first, a track as often as it was played (ADR 0022).
    case timeline
    /// The tracks a check of the health report found (ADR 0034).
    case health(HealthCheck)
    /// The timeline's plays in a span, as a bar of Listening Stats shows them (ADR 0102).
    case plays(PlaySpan)
    /// Listening Stats for a period, over the tracks played in it (ADR 0102).
    case stats(StatsPeriod)

    public static let playlistPrefix = "playlist:"
    private static let historyText = "history"
    private static let timelineText = "timeline"
    private static let healthPrefix = "health:"
    private static let playsPrefix = "plays:"
    private static let statsPrefix = "stats:"

    /// The source as one string, which the state file saves and the palette keys a playlist
    /// by.
    public var text: String {
        switch self {
        case .playlist(let id): Self.playlistPrefix + String(id)
        case .history: Self.historyText
        case .timeline: Self.timelineText
        case .health(let check): Self.healthPrefix + check.rawValue
        case .plays(let span): Self.playsPrefix + span.text
        case .stats(let period): Self.statsPrefix + period.text
        }
    }

    /// Whether the source lists plays, a row each, in the timeline, rather than tracks.
    public var listsPlays: Bool {
        switch self {
        case .timeline, .plays: true
        case .playlist, .history, .health, .stats: false
        }
    }

    /// Reads `text`; nil for a string that isn't one of the sources.
    public init?(text: String) {
        if text == Self.historyText {
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
        } else if text.hasPrefix(Self.playsPrefix),
            let span = PlaySpan(text: text.dropFirst(Self.playsPrefix.count))
        {
            self = .plays(span)
        } else if text.hasPrefix(Self.statsPrefix),
            case let period = text.dropFirst(Self.statsPrefix.count),
            // Only as the source writes it, so one period has one spelling in the file.
            let stats = StatsPeriod(text: period), stats.text == period
        {
            self = .stats(stats)
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
        "\"\(playlistPrefix)<id>\", \"\(historyText)\", \"\(timelineText)\","
            + " \"\(playsPrefix)<start>-<end>\", \"\(healthPrefix)<check>\" or"
            + " \"\(statsPrefix)<period>\""
    }
    public static var kind: SettingKind { .windowState }
}
