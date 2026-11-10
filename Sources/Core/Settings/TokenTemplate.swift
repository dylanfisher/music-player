/// Text with tokens in braces, such as `{title} — {artist}`, filled from the values the tokens
/// name: the playing track's for a `TitleTemplate` (ADR 0087), the status bar's totals for a
/// `TotalsTemplate` (ADR 0188). `{{` and `}}` write a brace; any other brace holds a token, so
/// an unknown name or a lone brace is the value's problem.
public struct TokenTemplate<Token: TemplateToken>: SettingValue {
    public enum Part: Equatable, Sendable {
        case text(String)
        case token(Token)
    }

    public let template: String
    /// The text and tokens in order; empty when the template has a problem.
    public let parts: [Part]
    private let templateProblem: String?

    public init(_ template: String) {
        self.template = template
        switch Self.parse(template) {
        case .success(let parts):
            self.parts = parts
            templateProblem = nil
        case .failure(let problem):
            parts = []
            templateProblem = problem.message
        }
    }

    public func problem() -> String? { templateProblem }

    public static var typeName: String {
        "a string with tokens in braces, such as \(Token.example)"
    }
    public static var kind: SettingKind {
        .template(Token.allCases.map { .init(name: $0.placeholder, help: $0.help) })
    }

    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(template)
    }

    private struct Problem: Error {
        var message: String
    }

    /// The template with each token's value, fields as they are; a blank value is empty. First,
    /// brackets, `(` or `[` and the matching closer, around tokens that are all empty go, with
    /// the spaces before them, or after them at the start. Then the text before each token
    /// belongs to it, except closing brackets right after a token that close one the line has
    /// open, which stay: the tokens with values are joined by the text just before each, so an
    /// empty one takes the text before it along. The text before the first token stays only
    /// when that token has a value, and the text after the last only when that one does, so
    /// nothing dangles at either end. The result is trimmed of spaces and newlines.
    public func fill(_ value: (Token) -> String?) -> String {
        let (parts, values) = Self.droppingEmptyGroups(parts) { token in
            value(token).flatMap { trimmed($0).isEmpty ? nil : $0 }
        }
        let tokens = parts.indices.filter { values[$0] != nil }
        guard let firstToken = tokens.first, let lastToken = tokens.last else {
            return trimmed(parts.map { if case .text(let text) = $0 { text } else { "" } }.joined())
        }
        let kept = tokens.filter { values[$0]?.isEmpty == false }
        guard let firstKept = kept.first else { return "" }
        var filled = ""
        var before = ""
        for index in parts.indices {
            switch parts[index] {
            case .text(let text):
                var rest = Substring(text)
                if index > 0, case .token = parts[index - 1] {
                    while let closer = rest.first, Self.closes(closer, in: filled) {
                        filled.append(closer)
                        rest = rest.dropFirst()
                    }
                }
                before += rest
            case .token:
                if kept.contains(index) {
                    if index != firstKept || index == firstToken { filled += before }
                    filled += values[index] ?? ""
                }
                before = ""
            }
        }
        if kept.last == lastToken { filled += before }
        return trimmed(filled)
    }

    /// Whether `closer` closes the last bracket `text` leaves open.
    private static func closes(_ closer: Character, in text: String) -> Bool {
        var open: [Character] = []
        for character in text {
            if let match = bracketClosers[character] {
                open.append(match)
            } else if open.last == character {
                open.removeLast()
            }
        }
        return open.last == closer
    }

    private enum Item {
        case character(Character)
        case token(Token, String)
    }

    /// `parts` without the bracketed groups whose tokens are all empty, and each token's
    /// value, "" when empty and nil for text. A bracket with no token before its match is plain
    /// text.
    private static func droppingEmptyGroups(
        _ parts: [Part], _ value: (Token) -> String?
    ) -> ([Part], [String?]) {
        let items: [Item] = parts.flatMap { part -> [Item] in
            switch part {
            case .text(let text): text.map { .character($0) }
            case .token(let token): [.token(token, value(token) ?? "")]
            }
        }
        var open: [(closer: Character, index: Int)] = []
        var dropped = Set<Int>()
        for (index, item) in items.enumerated() {
            guard case .character(let character) = item else { continue }
            if let closer = bracketClosers[character] {
                open.append((closer, index))
            } else if let last = open.last, last.closer == character {
                open.removeLast()
                let inside = items[last.index...index].compactMap { item -> String? in
                    guard case .token(_, let text) = item else { return nil }
                    return text
                }
                guard !inside.isEmpty, inside.allSatisfy(\.isEmpty) else { continue }
                dropped.formUnion(last.index...index)
                var before = last.index - 1
                while before >= 0, case .character(let c) = items[before], c.isWhitespace {
                    dropped.insert(before)
                    before -= 1
                }
                guard !(0..<last.index).contains(where: { !dropped.contains($0) }) else { continue }
                var after = index + 1
                while after < items.count, case .character(let c) = items[after], c.isWhitespace {
                    dropped.insert(after)
                    after += 1
                }
            }
        }
        var kept: [Part] = []
        var values: [String?] = []
        for (index, item) in items.enumerated() where !dropped.contains(index) {
            switch item {
            case .character(let character):
                if case .text(let text) = kept.last {
                    kept[kept.count - 1] = .text(text + String(character))
                } else {
                    kept.append(.text(String(character)))
                    values.append(nil)
                }
            case .token(let token, let text):
                kept.append(.token(token))
                values.append(text)
            }
        }
        return (kept, values)
    }

    /// The template read on Unicode scalars, so a brace followed by a combining mark is still a
    /// brace, or what's wrong with it.
    private static func parse(_ template: String) -> Result<[Part], Problem> {
        guard !trimmed(template).isEmpty else {
            return .failure(
                Problem(message: "empty; write a template such as \(Token.example)"))
        }
        let scalars = Array(template.unicodeScalars)
        var parts: [Part] = []
        var text = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let doubled = index + 1 < scalars.count && scalars[index + 1] == scalar
            switch scalar {
            case "{" where doubled, "}" where doubled:
                text.append(scalar)
                index += 2
            case "{":
                guard let close = scalars[(index + 1)...].firstIndex(of: "}") else {
                    return .failure(
                        Problem(message: "a { with no } after it; write {{ for a brace"))
                }
                let name = String(String.UnicodeScalarView(scalars[(index + 1)..<close]))
                guard let token = Token(rawValue: name) else {
                    let tokens = Token.allCases.map(\.placeholder).joined(separator: ", ")
                    return .failure(
                        Problem(message: "no token {\(name)}; the tokens are \(tokens)"))
                }
                if !text.isEmpty { parts.append(.text(String(text))) }
                text = String.UnicodeScalarView()
                parts.append(.token(token))
                index = close + 1
            case "}":
                return .failure(Problem(message: "a } with no { before it; write }} for a brace"))
            default:
                text.append(scalar)
                index += 1
            }
        }
        if !text.isEmpty { parts.append(.text(String(text))) }
        return .success(parts)
    }
}

/// The brackets a template's empty groups are found by, each with its closer.
private let bracketClosers: [Character: Character] = ["(": ")", "[": "]"]

private func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
}
