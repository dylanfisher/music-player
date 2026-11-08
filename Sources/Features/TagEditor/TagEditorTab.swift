import TagWriter

/// A tab of the info window and the fields it lays out, grouped as YATE groups them: the main
/// tags first, each sort field above the field it sorts, then credits, details, rights and
/// label, webpages (URLs), lyrics, the art and the file. Extras lists the keys no field maps.
enum TagEditorTab: String, CaseIterable {
    case info, sorting, credits, details, extras, rights, webpages, lyrics, artwork, file

    var title: String {
        switch self {
        case .info: "Info"
        case .sorting: "Sorting"
        case .credits: "Credits"
        case .details: "Details"
        case .extras: "Extras"
        case .rights: "Rights & Label"
        case .webpages: "URLs"
        case .lyrics: TagEditField.lyrics.title
        case .artwork: "Artwork"
        case .file: "File"
        }
    }

    /// The tab's rows of fields, top to bottom. The Extras, Artwork and File tabs show no
    /// fields.
    var rows: [TagEditorRow] {
        switch self {
        case .info:
            [
                .wide(.title), .pair(.artist, .date),
                .numbers(.albumArtist, .trackNumber, .trackTotal),
                .numbers(.album, .discNumber, .discTotal), .pair(.grouping, .bpm),
                .wide(.composer), .wide(.genre), .commentAndArt, .flag(.compilation),
            ]
        case .sorting:
            [
                .wide(.titleSort), .wide(.title), .gap, .wide(.artistSort), .wide(.artist), .gap,
                .wide(.albumArtistSort), .wide(.albumArtist), .gap, .wide(.albumSort),
                .wide(.album), .gap, .wide(.composerSort), .wide(.composer),
            ]
        case .credits:
            [.artist, .albumArtist, .composer, .conductor, .lyricist, .remixer, .originalArtist]
                .map(TagEditorRow.wide)
        case .details:
            [
                .pair(.mood, .key), .pair(.language, .media),
                .pair(.originalAlbum, .originalDate), .gap, .wide(.work),
                .numbers(.movementName, .movementNumber, .movementTotal), .wide(.discSubtitle),
                .gap, .wide(.description), .wide(.encoder),
            ]
        case .rights:
            [.copyright, .publisher, .catalogNumber, .barcode, .isrc].map(TagEditorRow.wide)
        case .webpages:
            [
                .artistURL, .audioFileURL, .audioSourceURL, .commercialURL, .copyrightURL,
                .paymentURL, .publisherURL, .radioStationURL,
            ].map(TagEditorRow.wide)
        case .lyrics: [.area(.lyrics)]
        case .extras, .artwork, .file: []
        }
    }
}

/// One row of a tab.
enum TagEditorRow: Equatable {
    /// A label and a field across the row.
    case wide(TagEditField)
    /// A field, then a short one at the right, such as the artist and the date.
    case pair(TagEditField, TagEditField)
    /// A field, then a number "of" a total at the right, such as the album and its disc.
    case numbers(TagEditField, TagEditField, TagEditField)
    /// A text area of several lines filling the tab.
    case area(TagEditField)
    /// The comment's text area with the art beside it, as YATE's Info tab has them.
    case commentAndArt
    case flag(TagEditField)
    /// Space between groups of rows.
    case gap

    var fields: [TagEditField] {
        switch self {
        case .wide(let field), .area(let field), .flag(let field): [field]
        case .pair(let a, let b): [a, b]
        case .numbers(let a, let b, let c): [a, b, c]
        case .commentAndArt: [.comment]
        case .gap: []
        }
    }
}
