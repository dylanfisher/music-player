/// A kind a typed search may name before a colon, as `album: dream` does (ADR 0161, 0220).
public protocol QueryKind: CaseIterable, Equatable {
    /// The words a query names this kind by, lowercased, before its colon.
    var queryNames: [String] { get }
}

extension QueryKind {
    /// "album: or a:", as a placeholder names them.
    public var queryPrefixes: String { queryNames.map { $0 + ":" }.joined(separator: " or ") }

    /// The kind `name` names, whatever its case; nil for any other word.
    public init?(queryName name: Substring) {
        let name = name.lowercased()
        guard let kind = Self.allCases.first(where: { $0.queryNames.contains(name) }) else {
            return nil
        }
        self = kind
    }
}
