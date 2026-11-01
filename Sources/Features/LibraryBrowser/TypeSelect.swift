import Foundation

/// Type-to-select: the text typed into a list since the last pause, and the row it picks. A key
/// a second or more after the last one starts a new query, as does any command or a change of
/// list. A repeated letter doesn't cycle: "rr" looks for "rr".
struct TypeSelect {
    static let resetSeconds = 1.0

    private(set) var query = ""
    private var lastKey = -Double.infinity
    private let now: () -> Double

    /// `now` is seconds on any steady clock, injected so tests needn't wait.
    init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// Whether a query is being typed, so Space joins it instead of playing.
    var isTyping: Bool { !query.isEmpty && now() - lastKey < Self.resetSeconds }

    /// Adds `text` and returns the whole query.
    mutating func add(_ text: String) -> String {
        let time = now()
        if time - lastKey >= Self.resetSeconds { query = "" }
        lastKey = time
        query += text
        return query
    }

    mutating func reset() {
        query = ""
        lastKey = -.infinity
    }

    /// The first of `texts`, in display order, that starts with `query`, ignoring case and
    /// accents, so "ré" finds "Resume".
    static func firstIndex(startingWith query: String, in texts: some Sequence<String>) -> Int? {
        let folded = fold(query)
        for (index, text) in texts.enumerated() where fold(text).hasPrefix(folded) {
            return index
        }
        return nil
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
