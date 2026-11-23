/// What a search field asks for: the text to match, and the one kind to list when it starts
/// with a kind's name and a colon, as `album: dream` does (ADR 0161, 0220). A word before the
/// colon that names no kind leaves the query as typed, so a title with a colon still matches.
public struct TypedQuery<Kind: QueryKind>: Equatable {
    public var text: String
    public var kind: Kind?

    public init(_ typed: String) {
        if let colon = typed.firstIndex(of: ":"), let kind = Kind(queryName: typed[..<colon]) {
            self.kind = kind
            text = String(typed[typed.index(after: colon)...].drop { $0 == " " })
        } else {
            kind = nil
            text = typed
        }
    }
}
