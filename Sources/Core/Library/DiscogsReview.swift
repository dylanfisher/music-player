/// What the user decided about an album in the Discogs tagger (ADR 0133), kept so a second
/// session doesn't redo the review.
public enum DiscogsReview: Equatable, Sendable {
    /// Not to be written: Apply to All leaves it out.
    case rejected
    /// The release the user chose from the candidates, which matching takes from then on.
    case chosen(releaseID: Int)
}

extension LibraryIndex {
    /// Records `review` for the tracks `fileIDs`, an album's; nil forgets it.
    func setDiscogsReview(_ review: DiscogsReview?, files fileIDs: [Int64]) throws {
        try database.transaction {
            let delete = try statement("DELETE FROM \(discogsReviewsTable) WHERE path_id = ?")
            let insert = try statement(
                "INSERT INTO \(discogsReviewsTable) (path_id, release_id) VALUES (?, ?)")
            for id in fileIDs {
                try delete.run(id)
                switch review {
                case nil: break
                case .rejected: try insert.run(id, nil)
                case .chosen(let releaseID): try insert.run(id, releaseID)
                }
            }
        }
    }

    /// Each reviewed album's review, by album ID: its first track's that has one.
    func discogsReviews() throws -> [Int64: DiscogsReview] {
        let rows = try statement(
            """
            SELECT t.album_id, r.release_id FROM \(discogsReviewsTable) r
            JOIN tracks t ON t.file_id = r.path_id
            WHERE t.album_id IS NOT NULL ORDER BY t.album_id, t.file_id
            """
        ).map { row in
            (
                try row.int64(0),
                row.optionalInt(1).map { DiscogsReview.chosen(releaseID: $0) } ?? .rejected
            )
        }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }
}
