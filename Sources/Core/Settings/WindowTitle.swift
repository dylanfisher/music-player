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

    /// The template with each token's value, fields as they are. First, brackets, `(` or `[`
    /// and the matching closer, around tokens that are all empty go, with the spaces before
    /// them, or after them at the start. Then text between two tokens shows only when the token
    /// before it has a value and one after it does, so a run of empty fields leaves the one
    /// separator after the last field shown; text before the first token shows only when that
    /// token has a value, and text after the last only when that one does.
    public func fill(_ value: (TitleToken) -> String?) -> String {
        let (parts, values) = Self.droppingEmptyGroups(parts, value)
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

    private enum Item {
        case character(Character)
        case token(TitleToken, String)
    }

    /// `parts` without the bracketed groups whose tokens are all empty, and each token's
    /// value, nil for text. A bracket with no token before its match is plain text.
    private static func droppingEmptyGroups(
        _ parts: [Part], _ value: (TitleToken) -> String?
    ) -> ([Part], [String?]) {
        let items: [Item] = parts.flatMap { part -> [Item] in
            switch part {
            case .text(let text): text.map { .character($0) }
            case .token(let token): [.token(token, value(token) ?? "")]
            }
        }
        let closers: [Character: Character] = ["(": ")", "[": "]"]
        var open: [(closer: Character, index: Int)] = []
        var dropped = Set<Int>()
        for (index, item) in items.enumerated() {
            guard case .character(let character) = item else { continue }
            if let closer = closers[character] {
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
