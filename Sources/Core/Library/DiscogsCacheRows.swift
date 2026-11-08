/// What the Discogs API returned for a release or a master, kept so a second look needs no
/// request (ADR 0138). The index holds the text only: what it means is the Discogs module's.
extension LibraryIndex {
    /// The entry for `id` of `kind`, and when it was fetched; nil when there's none.
    func discogsCached(kind: String, id: Int) throws -> (fetchedAt: Double, json: String)? {
        try statement(
            "SELECT fetched_at, json FROM \(discogsCacheTable) WHERE kind = ? AND id = ?"
        ).map(kind, id) { row in (try row.double(0), try row.text(1)) }.first
    }

    /// Keeps `json` for `id` of `kind`, fetched at `fetchedAt`, replacing any entry before.
    func storeDiscogs(kind: String, id: Int, fetchedAt: Double, json: String) throws {
        try statement(
            """
            INSERT OR REPLACE INTO \(discogsCacheTable) (kind, id, fetched_at, json)
            VALUES (?, ?, ?, ?)
            """
        ).run(kind, id, fetchedAt, json)
    }
}
