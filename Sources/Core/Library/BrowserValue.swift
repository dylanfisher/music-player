import SQLite

/// What a browser column's entry stands for: a row's ID in the genres, artists or albums table,
/// or the text a tag or file gives, for the other groupings.
public enum BrowserValue: Hashable, Sendable {
    case id(Int64)
    case text(String)

    /// The value bound in a query.
    var sqlValue: any SQLiteValue {
        switch self {
        case .id(let id): id
        case .text(let text): text
        }
    }
}
