/// The Vorbis comment keys of the fields the tag editor first wrote.
enum VorbisKey {
    static let title = "TITLE"
    static let artist = "ARTIST"
    static let album = "ALBUM"
    static let albumArtist = "ALBUMARTIST"
    static let genre = "GENRE"
    static let date = "DATE"
    static let trackNumber = "TRACKNUMBER"
    static let trackTotal = "TRACKTOTAL"
    static let discNumber = "DISCNUMBER"
    static let discTotal = "DISCTOTAL"
    static let compilation = "COMPILATION"
    static let composer = "COMPOSER"
    static let comment = "COMMENT"
}

/// The key the tag writer writes each field as, which the reader also reads. A number and its
/// total are two keys: `.track` and `.trackTotal`.
private let vorbisWrittenKeys: [TagField: String] = [
    .title: VorbisKey.title, .artist: VorbisKey.artist, .album: VorbisKey.album,
    .albumArtist: VorbisKey.albumArtist, .genre: VorbisKey.genre, .date: VorbisKey.date,
    .track: VorbisKey.trackNumber, .trackTotal: VorbisKey.trackTotal,
    .disc: VorbisKey.discNumber, .discTotal: VorbisKey.discTotal,
    .compilation: VorbisKey.compilation, .composer: VorbisKey.composer,
    .comment: VorbisKey.comment, .grouping: "GROUPING",
    .catalogNumber: SharedTagName.catalogNumber, .barcode: SharedTagName.barcode, .bpm: "BPM",
    .key: "KEY", .conductor: SharedTagName.conductor, .lyricist: SharedTagName.lyricist,
    .publisher: SharedTagName.label, .copyright: "COPYRIGHT", .encoder: "ENCODEDBY",
    .description: SharedTagName.description, .discSubtitle: SharedTagName.discSubtitle,
    .work: SharedTagName.work, .movement: "MOVEMENT", .movementTotal: "MOVEMENTTOTAL",
    .movementName: "MOVEMENTNAME", .originalDate: SharedTagName.originalDate,
    .titleSort: "TITLESORT", .artistSort: "ARTISTSORT", .albumSort: "ALBUMSORT",
    .albumArtistSort: "ALBUMARTISTSORT", .composerSort: "COMPOSERSORT",
    .remixer: SharedTagName.remixer, .originalArtist: SharedTagName.originalArtist,
    .originalAlbum: SharedTagName.originalAlbum, .isrc: SharedTagName.isrc,
    .language: SharedTagName.language, .mood: SharedTagName.mood, .media: SharedTagName.media,
    .lyrics: "LYRICS", .artistURL: SharedTagName.artistURL,
    .audioFileURL: SharedTagName.audioFileURL, .audioSourceURL: SharedTagName.audioSourceURL,
    .commercialURL: SharedTagName.commercialURL, .copyrightURL: SharedTagName.copyrightURL,
    .paymentURL: SharedTagName.paymentURL, .publisherURL: SharedTagName.publisherURL,
    .radioStationURL: SharedTagName.radioStationURL,
]

/// Vorbis comment keys, compared uppercased, and the fields they set: the written keys and other
/// taggers' spellings of the same fields.
private let vorbisFields: [String: TagField] = Dictionary(
    uniqueKeysWithValues: vorbisWrittenKeys.map { ($0.value, $0.key) }
).merging(
    [
        "ALBUM ARTIST": .albumArtist, "TOTALTRACKS": .trackTotal, "TOTALDISCS": .discTotal,
        "PUBLISHER": .publisher, "UNSYNCEDLYRICS": .lyrics,
    ],
    uniquingKeysWith: { written, _ in written })

/// The key the tag writer writes `field` as; nil for none.
package func vorbisWrittenKey(for field: TagField) -> String? { vorbisWrittenKeys[field] }

/// The keys, uppercased, that the reader maps onto `field`, so a writer replaces exactly those.
package func vorbisKeys(for field: TagField) -> Set<String> {
    Set(vorbisFields.compactMap { key, each in each == field ? key : nil })
}

/// Little-endian lengths, unlike the rest of FLAC: the vendor string, the comment count, then each
/// comment as `KEY=value` in UTF-8. Keys no field maps are the custom ones.
package func parseVorbisComment(_ block: Bytes, _ reader: ByteReader) throws(ParseFailure)
    -> TrackTags
{
    var tags = TrackTags()
    var cursor = 4 + Int(try block.uint32LE(0))
    let count = Int(try block.uint32LE(cursor))
    cursor += 4
    // Each comment takes at least its 4-byte length, so a larger count can't be real.
    guard count <= (block.count - cursor) / 4 else {
        throw .malformed(
            at: block.fileOffset(cursor - 4),
            "Vorbis comment count \(count) doesn't fit in its \(block.count)-byte block")
    }
    for _ in 0..<count {
        try reader.step(at: block.fileOffset(cursor))
        let length = Int(try block.uint32LE(cursor))
        guard length <= block.count - cursor - 4 else {
            throw .malformed(
                at: block.fileOffset(cursor),
                "Vorbis comment of \(length) bytes runs past the end of its block")
        }
        let comment = try block.slice(cursor + 4..<cursor + 4 + length)
        let offset = block.fileOffset(cursor)
        cursor += 4 + length
        let bytes = comment.array
        guard let equals = bytes.firstIndex(of: UInt8(ascii: "=")) else {
            reader.warn(.unreadableField, at: offset, "Vorbis comment without \"=\"; skipped")
            continue
        }
        let key = latin1(bytes[..<equals]).uppercased()
        let text = TextEncoding.utf8.decode(
            Array(bytes[(equals + 1)...]), at: offset, warnings: &reader.warnings)
        if let field = vorbisFields[key] {
            tags.set(field, text, at: offset, warnings: &reader.warnings)
        } else {
            tags.setCustom(key, text, at: offset, warnings: &reader.warnings)
        }
    }
    return tags
}
