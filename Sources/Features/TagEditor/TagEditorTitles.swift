import TagWriter

extension TagEditField {
    /// The field's label in the editor.
    var title: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .albumArtist: "Album Artist"
        case .genre: "Genre"
        case .date: "Date"
        case .composer: "Composer"
        case .comment: "Comment"
        case .trackNumber: "Track"
        case .trackTotal, .discTotal: "of"
        case .discNumber: "Disc"
        case .compilation: "Part of a compilation"
        }
    }
}

/// What a field shows when the selected tracks differ in it.
let mixedPlaceholder = "Mixed"
