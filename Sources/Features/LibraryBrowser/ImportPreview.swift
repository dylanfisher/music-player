/// What the import sheet's table shows: a heading for how many tracks matched, a row for each
/// field the import changes with how many, the fields it changes nothing in, and notes about
/// what it leaves out.
struct ImportPreview: Equatable {
    struct Row: Equatable {
        /// What changes, such as "Play counts".
        var change: String
        /// How many, such as "+1,204 on 800 tracks".
        var count: String
    }

    var heading: String
    var rows: [Row]
    /// "No change: last played, date added, ratings, loved"; nil when every field changes.
    var unchanged: String?
    /// What isn't brought across, such as "32 rows for a track already read, merged into it",
    /// one line under the table.
    var notes: [String]
}
