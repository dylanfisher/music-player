/// An album's run of adjacent rows, which full-width art spans: the art is drawn once, from the
/// top of the run's first row, as tall as it is wide, so it covers that many rows.
enum ArtRun {
    /// The first row of `row`'s run, or nil when `row` is below the art, `rowsTall` rows or more
    /// from the run's start. A row with no album is a run of its own. Looks back at most
    /// `rowsTall` rows, so a long album costs no more than a short one.
    static func start(of row: Int, rowsTall: Int, album: (Int) -> Int64?) -> Int? {
        guard let id = album(row) else { return row }
        var start = row
        while start > 0, row - start < rowsTall, album(start - 1) == id { start -= 1 }
        return row - start < rowsTall ? start : nil
    }
}
