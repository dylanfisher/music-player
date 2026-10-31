import Foundation

/// Chunk sizes are little-endian in RIFF (WAV) and big-endian in IFF (AIFF).
enum ByteOrder {
    case little, big
}

/// A chunk with its header, padded to an even length as both formats require.
func riffChunk(_ id: String, _ body: Data, _ order: ByteOrder) -> Data {
    var chunk = Data()
    chunk.append(ascii: id)
    switch order {
    case .little: chunk.appendLittleEndian(UInt32(body.count))
    case .big: chunk.appendBigEndian(UInt32(body.count))
    }
    chunk.append(body)
    if body.count % 2 == 1 { chunk.append(0) }
    return chunk
}

/// `RIFF…WAVE` or `FORM…AIFF` around `chunks`.
func riffForm(_ type: String, chunks: Data, _ order: ByteOrder) -> Data {
    var body = Data()
    body.append(ascii: type)
    body.append(chunks)
    return riffChunk(order == .little ? "RIFF" : "FORM", body, order)
}

/// A `LIST` chunk of type `INFO`, which holds only plain text fields. The values are UTF-8, as
/// most taggers write them, with a terminating NUL.
func riffInfoChunk(_ tags: FixtureTags) -> Data {
    let fields: [(String, String?)] = [
        ("INAM", tags.title), ("IART", tags.artist), ("IPRD", tags.album),
        ("IGNR", tags.genre), ("ICRD", tags.date), ("ITRK", tags.trackNumber.map(String.init)),
        ("ICMT", tags.comment),
    ]
    var body = Data()
    body.append(ascii: "INFO")
    for case (let id, let value?) in fields {
        body.append(riffChunk(id, Data(value.utf8) + [0], .little))
    }
    return riffChunk("LIST", body, .little)
}

/// What a `LIST/INFO` chunk can hold of `tags`.
func riffInfoSubset(_ tags: FixtureTags) -> FixtureTags {
    FixtureTags(
        title: tags.title, artist: tags.artist, album: tags.album, genre: tags.genre,
        date: tags.date, trackNumber: tags.trackNumber, compilation: false, comment: tags.comment)
}
