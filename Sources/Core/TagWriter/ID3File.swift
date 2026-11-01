import Metadata

/// A file whose tags are one ID3v2 tag: at the start of an MP3, or in the `ID3 ` chunk of an
/// AIFF or the `id3 ` chunk of a WAV.
struct ID3File {
    enum Host {
        case mp3
        /// `littleEndian` for RIFF; `chunk` is nil when the file has no tag chunk yet.
        case form(littleEndian: Bool, chunk: RIFFChunk?, chunks: [RIFFChunk], formEnd: Int)
    }

    var container: TagLayout.Container
    var size: Int
    var host: Host
    var tag: ID3Tag
    var payload: Range<Int>

    init(_ reader: ByteReader, container: TagLayout.Container) throws(ParseFailure) {
        self.container = container
        size = reader.size
        switch container {
        case .mp3:
            host = .mp3
            let head = try reader.bytes(0..<min(ID3Tag.headerBytes, reader.size))
            if head.matches(id3v2Identifier, at: 0) {
                guard let body = try head.syncsafe(6) else {
                    throw .malformed(at: 6, "ID3v2 tag size isn't a syncsafe integer")
                }
                let count = ID3Tag.headerBytes + body
                guard count <= reader.size else {
                    throw .malformed(at: 0, "ID3v2 tag runs past the end of the file")
                }
                tag = try ID3Tag(try reader.bytes(0..<count).array, at: 0)
            } else {
                tag = ID3Tag(newAt: 0)
            }
            payload = tag.byteCount..<reader.size
        case .aiff, .wav:
            let littleEndian = container == .wav
            let form = container == .wav ? riffFormID : aiffFormID
            let header = try reader.bytes(0..<12)
            let declared = Int(littleEndian ? try header.uint32LE(4) : try header.uint32BE(4))
            let end = try formEnd(reader, size: declared, form: form)
            guard !reader.warnings.contains(where: { $0.kind == .truncated }), 8 + declared == end
            else {
                throw .unsupported(at: 4, "writing tags in a \(form) form cut off or streamed")
            }
            var chunks: [RIFFChunk] = []
            try forEachChunk(reader, in: 12..<end, littleEndian: littleEndian, form: form) {
                chunks.append($0)
            }
            let audioID = container == .wav ? "data" : "SSND"
            guard let audio = chunks.first(where: { $0.id == audioID }) else {
                throw .malformed(at: 12, "\(form) without a '\(audioID)' chunk")
            }
            payload = audio.body
            let chunk = chunks.first { $0.id == aiffID3ChunkID || $0.id == wavID3ChunkID }
            if let chunk {
                tag = try ID3Tag(try reader.bytes(chunk.body).array, at: chunk.body.lowerBound)
            } else {
                tag = ID3Tag(newAt: end + 8)
            }
            host = .form(littleEndian: littleEndian, chunk: chunk, chunks: chunks, formEnd: end)
        case .flac, .mp4:
            preconditionFailure("\(container) has no ID3 tag")
        }
    }

    func rewrite(
        _ groups: [TagGroup], from tags: TrackTags, art: ArtChange?, artOffset: Int?
    ) throws(ParseFailure) -> [Segment] {
        var tag = self.tag
        try tag.apply(groups, from: tags, art: art, artOffset: artOffset)
        let bytes = try tag.rewritten()
        switch host {
        case .mp3:
            return [.bytes(bytes), .original(self.tag.byteCount..<size)]
        case .form(let littleEndian, let chunk, let chunks, let formEnd):
            let order = { (value: Int) in
                littleEndian ? littleEndianBytes(value, 4) : bigEndianBytes(value, 4)
            }
            let id = chunk?.id ?? (littleEndian ? wavID3ChunkID : aiffID3ChunkID)
            var segments: [Segment] = []
            var replacedStart = formEnd
            var replacedEnd = formEnd
            var body: [Segment] = [.bytes(bytes)]
            var bodyCount = bytes.count
            if let chunk {
                replacedStart = chunk.start
                replacedEnd = min(formEnd, chunk.body.upperBound + chunk.body.count % 2)
                let extra = chunk.body.lowerBound + self.tag.byteCount..<chunk.body.upperBound
                if !extra.isEmpty {
                    body.append(.original(extra))
                    bodyCount += extra.count
                }
            }
            // A last chunk may leave out its pad byte; one goes in before a new chunk after it.
            var lead: [UInt8] = []
            if chunk == nil, let last = chunks.last, last.body.count % 2 == 1,
                last.body.upperBound == formEnd
            {
                lead = [0]
            }
            var chunkBytes: [Segment] = [.bytes(lead + Array(id.utf8) + order(bodyCount))] + body
            if bodyCount % 2 == 1 { chunkBytes.append(.bytes([0])) }
            let newFormEnd =
                formEnd - (replacedEnd - replacedStart) + chunkBytes.reduce(0) { $0 + $1.count }
            let form = Array(container == .wav ? riffFormID.utf8 : aiffFormID.utf8)
            segments.append(.bytes(form + order(newFormEnd - 8)))
            segments.append(.original(8..<replacedStart))
            segments += chunkBytes
            segments.append(.original(replacedEnd..<size))
            return segments.filter { $0.count > 0 }
        }
    }

    func layout() -> TagLayout {
        var notes = ["ID3v2.\(tag.version)"]
        if tag.byteCount == 0 { notes = ["no ID3v2 tag"] }
        switch host {
        case .mp3:
            var blocks = tag.byteCount > 0 ? tag.blocks(prefix: id3v2Identifier) : []
            blocks.append(TagBlock(audioFramesPath, payload, .audio))
            return TagLayout(container: .mp3, blocks: blocks, payload: [payload], notes: notes)
        case .form(_, let chunk, let chunks, let formEnd):
            let form = container == .wav ? riffFormID : aiffFormID
            var blocks = [TagBlock(form, 0..<12, .header)]
            for each in chunks {
                let range = each.start..<each.body.upperBound
                if each.start == chunk?.start {
                    blocks.append(TagBlock(each.id, each.start..<each.body.lowerBound, .header))
                    blocks += tag.blocks(prefix: each.id)
                    let extra = each.body.lowerBound + tag.byteCount..<each.body.upperBound
                    if !extra.isEmpty { blocks.append(TagBlock("\(each.id)/extra", extra, .other)) }
                } else if each.body == payload {
                    blocks.append(TagBlock(each.id, each.start..<each.body.lowerBound, .other))
                    blocks.append(TagBlock("\(each.id)/audio", each.body, .audio))
                } else {
                    blocks.append(TagBlock(each.id, range, .other))
                }
            }
            if let chunk, chunk.start < payload.lowerBound {
                notes.append("ID3 chunk before the audio")
            } else if chunk != nil {
                notes.append("ID3 chunk after the audio")
            }
            if formEnd < size { notes.append("\(size - formEnd) bytes after the form") }
            return TagLayout(container: container, blocks: blocks, payload: [payload], notes: notes)
        }
    }
}
