import Foundation

/// `appearance.headerTitleFormat`: the toolbar's Title Line, as text with fields in braces,
/// `{title} by {artist} from {album}`. Stored as the string the owner wrote; a field the
/// format doesn't know, or a brace left open, is a problem with the setting.
public struct TitleFormat: SettingValue {
    /// What a format can show: the playing track's text the toolbar's status already has.
    public enum Field: String, CaseIterable, Sendable {
        case title, artist, album
    }

    public var text: String

    init(_ text: String) { self.text = text }

    public init(from decoder: any Decoder) throws {
        text = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    public static var typeName: String { String.typeName }
    public static var kind: SettingKind { .string }

    /// Swinsian's toolbar line: "FI3AC2384210 by Aleksi Perälä from Alithia E'".
    public static let defaultHeaderTitle = TitleFormat("{title} by {artist} from {album}")

    public func problem() -> String? {
        switch pieces {
        case .success: nil
        case .failure(let problem): problem.text
        }
    }

    /// The line for a track with these fields' values. An empty field goes with the text just
    /// before it, so "{title} by {artist}" with no artist is the title alone, and the line is
    /// trimmed at both ends.
    public func line(_ values: [Field: String]) -> String {
        guard case .success(let pieces) = pieces else {
            preconditionFailure("\(text.debugDescription) is an invalid title format")
        }
        var line = ""
        var before = ""
        for piece in pieces {
            switch piece {
            case .text(let text): before += text
            case .field(let field):
                let value = values[field] ?? ""
                if !value.trimmingCharacters(in: .whitespaces).isEmpty { line += before + value }
                before = ""
            }
        }
        return (line + before).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum Piece: Equatable {
        case text(String)
        case field(Field)
    }

    struct Problem: Error {
        var text: String
    }

    /// The format's text and fields in order, or what's wrong with it.
    var pieces: Result<[Piece], Problem> {
        var pieces: [Piece] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            if open > rest.startIndex { pieces.append(.text(String(rest[..<open]))) }
            guard let close = rest[open...].firstIndex(of: "}") else {
                return .failure(Problem(text: "a { isn't closed with a }"))
            }
            let name = rest[rest.index(after: open)..<close]
            guard let field = Field(rawValue: String(name)) else {
                let fields = Field.allCases.map { "{\($0.rawValue)}" }.joined(separator: ", ")
                return .failure(
                    Problem(text: "{\(name)} isn't a field; the fields are \(fields)"))
            }
            pieces.append(.field(field))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { pieces.append(.text(String(rest))) }
        return .success(pieces)
    }
}
