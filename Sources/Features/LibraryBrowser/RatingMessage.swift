import DisplayText

/// What the status bar says after a rating from a menu or a shortcut: "Rated “Title” ★★★★",
/// "Rated 3 tracks ★★★★", or "Cleared the rating of “Title”". `title` is the one track's; nil
/// counts the tracks instead.
func ratingMessage(stars: Int, count: Int, title: String?) -> String {
    let rated = title.map { "“\($0)”" } ?? tracks(count)
    return stars == 0
        ? "Cleared the rating of \(rated)" : "Rated \(rated) \(DisplayText.stars(stars))"
}
