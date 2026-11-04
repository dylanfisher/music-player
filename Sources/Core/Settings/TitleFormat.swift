import Foundation

/// `appearance.headerTitleFormat`: the toolbar's Title Line, as text with fields in braces,
/// `{title} by {artist} from {album}`, and `{{` and `}}` for a brace. Stored as the string the
/// owner wrote; an empty format, a field the format doesn't know, or a brace without its pair is
/// a problem with the setting.
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
        switch parsed {
        case .success: nil
        case .failure(let problem): problem.text
        }
    }

    /// The line for a track whose fields have the values `value` gives; nil or blank is empty.
    /// The fields with values are joined by the text just before each, so an empty field takes
    /// the text before it along. The text before the first field stays only when that field has
    /// a value, and the text after the last only when that one does, so nothing dangles at
    /// either end: `{artist} - {title}` with no artist is the title alone. The line is trimmed.
    public func line(_ value: (Field) -> String?) -> String {
        guard case .success(let parsed) = parsed else {
            preconditionFailure("\(text.debugDescription) is an invalid title format")
        }
        guard !parsed.fields.isEmpty else { return trimmed(parsed.end) }
        let kept = parsed.fields.enumerated().compactMap { index, piece in
            value(piece.field).flatMap { trimmed($0).isEmpty ? nil : (index, $0) }
        }
        guard let first = kept.first?.0, let last = kept.last?.0 else { return "" }
        var line = first == 0 ? parsed.fields[0].before : ""
        for (position, (index, text)) in kept.enumerated() {
            if position > 0 { line += parsed.fields[index].before }
            line += text
        }
        if last == parsed.fields.count - 1 { line += parsed.end }
        return trimmed(line)
    }

    /// The format's fields, each with the text just before it, and the text after the last.
    struct Parsed {
        var fields: [(before: String, field: Field)]
        var end: String
    }

    struct Problem: Error {
        var text: String
    }

    /// The format read on Unicode scalars, so a brace followed by a combining mark is still a
    /// brace, or what's wrong with it.
    var parsed: Result<Parsed, Problem> {
        guard !trimmed(text).isEmpty else {
            return .failure(Problem(text: "the format is empty; it needs a field such as {title}"))
        }
        let scalars = Array(text.unicodeScalars)
        var parsed = Parsed(fields: [], end: "")
        var literal = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let doubled = index + 1 < scalars.count && scalars[index + 1] == scalar
            switch scalar {
            case "{" where doubled, "}" where doubled:
                literal.append(scalar)
                index += 2
            case "{":
                guard let close = scalars[index...].firstIndex(of: "}") else {
                    return .failure(
                        Problem(text: "a { isn't closed with a }; write {{ for a brace"))
                }
                let name = String(String.UnicodeScalarView(scalars[(index + 1)..<close]))
                guard let field = Field(rawValue: name) else {
                    let fields = Field.allCases.map { "{\($0.rawValue)}" }.joined(separator: ", ")
                    return .failure(
                        Problem(text: "{\(name)} isn't a field; the fields are \(fields)"))
                }
                parsed.fields.append((String(literal), field))
                literal = String.UnicodeScalarView()
                index = close + 1
            case "}":
                return .failure(Problem(text: "a } has no { before it; write }} for a brace"))
            default:
                literal.append(scalar)
                index += 1
            }
        }
        parsed.end = String(literal)
        return .success(parsed)
    }
}

private func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
}
