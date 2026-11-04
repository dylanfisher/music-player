/// What `appearance.windowTitle` holds: text with tokens in braces, such as
/// `{title} — {artist}`, which the window's title fills from the playing track (ADR 0087).
/// Braces only ever hold a token, so an unknown name or a stray brace is the value's problem.
public struct WindowTitle: SettingValue {
    public enum Part: Equatable, Sendable {
        case text(String)
        case token(TitleToken)
    }

    public let template: String
    /// The text and tokens in order; empty when the template has a problem.
    public let parts: [Part]
    private let templateProblem: String?

    public static let `default` = WindowTitle("{title} — {artist}")

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

    public static var typeName: String { "a string with tokens in braces, such as {title}" }
    public static var kind: SettingKind {
        .template(TitleToken.allCases.map { .init(name: $0.placeholder, help: $0.help) })
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

    /// The template with each token's value, fields as they are. Text between two tokens shows
    /// only when the token before it has a value and one after it does, so a run of empty
    /// fields leaves the one separator after the last field shown; text before the first token
    /// shows only when that token has a value, and text after the last only when that one does.
    public func fill(_ value: (TitleToken) -> String?) -> String {
        let values: [String?] = parts.map { part in
            guard case .token(let token) = part else { return nil }
            return value(token) ?? ""
        }
        func hasValue(_ index: Int) -> Bool { values[index]?.isEmpty == false }
        let tokens = parts.indices.filter { values[$0] != nil }
        return parts.indices.map { index -> String in
            guard case .text(let text) = parts[index] else { return values[index] ?? "" }
            let before = tokens.last { $0 < index }
            let after = tokens.filter { $0 > index }
            let shows =
                switch (before, after.first) {
                case (nil, nil): true
                case (nil, let next?): hasValue(next)
                case (let previous?, nil): hasValue(previous)
                case (let previous?, _): hasValue(previous) && after.contains(where: hasValue)
                }
            return shows ? text : ""
        }.joined()
    }

    private static func parse(_ template: String) -> Result<[Part], Problem> {
        guard !template.isEmpty else {
            return .failure(
                Problem(
                    message: "empty; write the window's title, such as \(Self.default.template)"))
        }
        var parts: [Part] = []
        var rest = Substring(template)
        while !rest.isEmpty {
            guard let open = rest.firstIndex(where: { $0 == "{" || $0 == "}" }) else {
                parts.append(.text(String(rest)))
                break
            }
            if open > rest.startIndex { parts.append(.text(String(rest[..<open]))) }
            guard rest[open] == "{" else {
                return .failure(Problem(message: "a } with no { before it"))
            }
            let name = rest[rest.index(after: open)...].prefix { $0 != "}" }
            guard name.endIndex < rest.endIndex else {
                return .failure(Problem(message: "a { with no } after it"))
            }
            guard let token = TitleToken(rawValue: String(name)) else {
                let tokens = TitleToken.allCases.map(\.placeholder).joined(separator: ", ")
                return .failure(Problem(message: "no token {\(name)}; the tokens are \(tokens)"))
            }
            parts.append(.token(token))
            rest = rest[rest.index(after: name.endIndex)...]
        }
        return .success(parts)
    }
}
