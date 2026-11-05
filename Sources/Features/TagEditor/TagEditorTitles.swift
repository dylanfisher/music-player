import Library
import Settings
import TagWriter

extension TagEditField {
    /// The field's label in the editor: the smart rule field's or column's title where the two
    /// read the same.
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
        case .trackNumber: TrackColumn.trackNumber.title
        case .trackTotal, .discTotal, .movementTotal: "of"
        case .discNumber: TrackColumn.discNumber.title
        case .compilation: "Part of a compilation"
        case .grouping: TrackColumn.grouping.title
        case .bpm: TrackColumn.bpm.title
        case .key: TrackColumn.key.title
        case .conductor: TrackColumn.conductor.title
        case .lyricist: TrackColumn.lyricist.title
        case .remixer: "Remixer"
        case .originalArtist: "Original Artist"
        case .publisher: "Label"
        case .copyright: TrackColumn.copyright.title
        case .catalogNumber: "Catalog Number"
        case .barcode: TrackColumn.barcode.title
        case .isrc: "ISRC"
        case .encoder: "Encoded By"
        case .description: TrackColumn.description.title
        case .discSubtitle: TrackColumn.discSubtitle.title
        case .work: TrackColumn.work.title
        case .movementNumber: "Movement"
        case .movementName: "Movement Name"
        case .originalDate: TrackColumn.originalDate.title
        case .originalAlbum: "Original Album"
        case .language: "Language"
        case .mood: "Mood"
        case .media: "Media"
        case .lyrics: "Lyrics"
        case .titleSort: "Sort Title"
        case .artistSort: "Sort Artist"
        case .albumSort: "Sort Album"
        case .albumArtistSort: "Sort Album Artist"
        case .composerSort: "Sort Composer"
        case .artistURL: "Artist Webpage"
        case .audioFileURL: "Audio File Webpage"
        case .audioSourceURL: "Audio Source Webpage"
        case .commercialURL: "Commercial Webpage"
        case .copyrightURL: "Copyright Webpage"
        case .paymentURL: "Payment Webpage"
        case .publisherURL: "Publisher Webpage"
        case .radioStationURL: "Radio Station Webpage"
        }
    }
}

/// What a field shows when the selected tracks differ in it.
let mixedPlaceholder = "Mixed"
