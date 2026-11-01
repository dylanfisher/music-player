import Library
import Settings
import TagWriter

extension TagEditField {
    /// The field's label in the editor: the smart rule field's title where the two read the same.
    var title: String {
        switch self {
        case .title: SmartField.title.title
        case .artist: SmartField.artist.title
        case .album: SmartField.album.title
        case .albumArtist: SmartField.albumArtist.title
        case .genre: SmartField.genre.title
        case .date: "Date"
        case .composer: SmartField.composer.title
        case .comment: SmartField.comment.title
        case .trackNumber: "Track"
        case .trackTotal, .discTotal: "of"
        case .discNumber: TrackColumn.discNumber.title
        case .compilation: "Part of a compilation"
        }
    }
}

/// What a field shows when the selected tracks differ in it.
let mixedPlaceholder = "Mixed"
