/// An MP4 atom: a 32-bit size (1 means a 64-bit size follows, 0 means "to the end of the file" at
/// the top level), a four-character type, then the body.
struct Atom {
    var type: String
    var start: Int
    var body: Range<Int>
}

/// MP4 and M4A: walks the top-level atoms to `moov`, wherever it sits, then reads the first sound
/// track's `mdhd` and `stsd` and the iTunes `ilst` under `udta/meta`. `mdat` is skipped by length.
func parseMP4(_ reader: ByteReader) throws(ParseFailure) -> TrackMetadata {
    var moov: Atom?
    try forEachAtom(reader, in: 0..<reader.size, parent: nil) { atom throws(ParseFailure) in
        if atom.type == "moov" { moov = atom }
        return moov == nil
    }
    guard let moov else { throw .malformed(at: 0, "MP4 without a moov atom") }

    var track: TrackAudio?
    var items = ILSTItems()
    try forEachAtom(reader, in: moov.body, parent: moov) { child throws(ParseFailure) in
        switch child.type {
        case "trak" where track == nil: track = try soundTrack(reader, child)
        case "udta": items = try metadataItems(reader, child)
        default: break
        }
        return true
    }
    guard var audio = track else {
        throw .malformed(at: moov.start, "MP4 without a sound track")
    }
    if audio.codec == .aac, let length = items.gaplessLength { audio.lengthFrames = length }
    return TrackMetadata(tags: items.tags, audio: audio, art: items.art)
}

/// Calls `body` with each atom that tiles `range`, until it returns false. QuickTime ends a
/// container with a 32-bit zero terminator, so inside a parent fewer than 8 bytes left, or an
/// atom of size 0, ends the walk.
func forEachAtom(
    _ reader: ByteReader, in range: Range<Int>, parent: Atom?,
    _ body: (Atom) throws(ParseFailure) -> Bool
) throws(ParseFailure) {
    let parentName = parent.map { "'\($0.type)'" } ?? "the file"
    var offset = range.lowerBound
    while offset < range.upperBound {
        guard range.upperBound - offset >= 8 else {
            if parent != nil { return }
            throw .malformed(
                at: offset, "\(range.upperBound - offset) stray bytes at the end of \(parentName)")
        }
        let header = try reader.bytes(offset..<offset + 8)
        let type = try header.fourCC(4)
        var size = Int(try header.uint32BE(0))
        if size == 0, parent != nil { return }
        var headerSize = 8
        if size == 1 {
            let large = try reader.bytes(offset + 8..<offset + 16).uint64BE(0)
            guard large <= UInt64(Int.max) else {
                throw .malformed(at: offset, "MP4 atom '\(type)' has a 64-bit size of \(large)")
            }
            size = Int(large)
            headerSize = 16
        } else if size == 0 {
            size = range.upperBound - offset
        }
        guard size >= headerSize else {
            throw .malformed(
                at: offset, "MP4 atom '\(type)' has size \(size), smaller than its header")
        }
        guard size <= range.upperBound - offset else {
            throw .malformed(
                at: offset,
                "MP4 atom '\(type)' of \(size) bytes runs past the end of \(parentName)")
        }
        let atom = Atom(type: type, start: offset, body: offset + headerSize..<offset + size)
        guard try body(atom) else { return }
        offset += size
    }
}

/// The first child of `parent` with type `type`.
private func child(_ reader: ByteReader, _ parent: Atom, _ type: String, at start: Int? = nil)
    throws(ParseFailure) -> Atom?
{
    let start = start ?? parent.body.lowerBound
    guard start <= parent.body.upperBound else {
        throw .malformed(at: parent.start, "MP4 '\(parent.type)' is too short for its fields")
    }
    var found: Atom?
    try forEachAtom(
        reader, in: start..<parent.body.upperBound, parent: parent
    ) {
        atom throws(ParseFailure) in
        if atom.type == type { found = atom }
        return found == nil
    }
    return found
}

private func require(_ reader: ByteReader, _ parent: Atom, _ type: String) throws(ParseFailure)
    -> Atom
{
    guard let atom = try child(reader, parent, type) else {
        throw .malformed(at: parent.start, "MP4 '\(parent.type)' without a '\(type)' atom")
    }
    return atom
}

/// Nil when the track isn't sound. `mdhd` gives the length in its own timescale; `stsd` gives
/// the codec, and for ALAC and AAC the real rate, which the sample entry's 16.16 field can't hold
/// above 65535 Hz.
private func soundTrack(_ reader: ByteReader, _ trak: Atom) throws(ParseFailure) -> TrackAudio? {
    let mdia = try require(reader, trak, "mdia")
    let handler = try reader.bytes(try require(reader, mdia, "hdlr").body)
    guard try handler.fourCC(8) == "soun" else { return nil }

    let mdhd = try reader.bytes(try require(reader, mdia, "mdhd").body)
    let version = try mdhd.uint8(0)
    let timescale = Int(try mdhd.uint32BE(version == 1 ? 20 : 12))
    let duration = version == 1 ? try mdhd.uint64BE(24) : UInt64(try mdhd.uint32BE(16))
    guard timescale > 0 else { throw .malformed(at: mdhd.fileOffset(0), "MP4 mdhd timescale is 0") }

    let stbl = try require(reader, try require(reader, mdia, "minf"), "stbl")
    let stsd = try require(reader, stbl, "stsd")
    // Version and flags, then the entry count, then the entries.
    guard stsd.body.count >= 8 else {
        throw .malformed(at: stsd.start, "MP4 stsd is too short for its entry count")
    }
    var entry: Atom?
    try forEachAtom(reader, in: stsd.body.lowerBound + 8..<stsd.body.upperBound, parent: stsd) {
        atom throws(ParseFailure) in
        entry = atom
        return false
    }
    guard let entry else { throw .malformed(at: stsd.start, "MP4 stsd has no sample entries") }
    var audio = try sampleEntry(reader, entry)

    guard duration <= UInt64(Int.max / max(audio.sampleRateHz, 1)) else {
        throw .malformed(at: mdhd.fileOffset(0), "MP4 mdhd duration \(duration) is too large")
    }
    audio.lengthFrames = Int(duration) * audio.sampleRateHz / timescale
    return audio
}

/// An audio sample entry: 8 reserved bytes, version, revision, vendor, channels, sample size,
/// compression ID, packet size and a 16.16 sample rate, then (for versions 1 and 2) more fields,
/// then child atoms. `lengthFrames` is left for the caller.
private func sampleEntry(_ reader: ByteReader, _ entry: Atom) throws(ParseFailure) -> TrackAudio {
    let fields = try reader.bytes(
        entry.body.lowerBound..<min(entry.body.upperBound, entry.body.lowerBound + 28))
    let version = try fields.uint16BE(8)
    let channels = Int(try fields.uint16BE(16))
    let childrenStart: Int
    switch version {
    case 0: childrenStart = 28
    case 1: childrenStart = 28 + 16
    case 2: childrenStart = 28 + 36
    default:
        throw .unsupported(at: entry.start, "MP4 audio sample entry version \(version)")
    }
    let start = entry.body.lowerBound + childrenStart
    switch entry.type {
    case "alac":
        guard let cookie = try child(reader, entry, "alac", at: start) else {
            throw .malformed(at: entry.start, "MP4 ALAC sample entry without its 'alac' cookie")
        }
        // Version and flags, frame length, compatible version, then bit depth, three tuning
        // bytes, channels, max run, max frame bytes, average bit rate and sample rate.
        let config = try reader.bytes(cookie.body)
        let rate = Int(try config.uint32BE(24))
        guard rate > 0 else { throw .malformed(at: cookie.start, "ALAC sample rate is 0") }
        return TrackAudio(
            codec: .alac, sampleRateHz: rate, bitsPerSample: Int(try config.uint8(9)),
            channels: Int(try config.uint8(13)), lengthFrames: 0)
    case "mp4a":
        guard let esds = try child(reader, entry, "esds", at: start) else {
            throw .malformed(at: entry.start, "MP4 mp4a sample entry without an 'esds' atom")
        }
        let config = try audioSpecificConfig(try reader.bytes(esds.body).suffix(from: 4))
        return TrackAudio(
            codec: .aac, sampleRateHz: config.sampleRateHz, bitsPerSample: nil,
            channels: config.channels ?? channels, lengthFrames: 0)
    default:
        throw .unsupported(at: entry.start, "MP4 codec '\(entry.type)'")
    }
}
