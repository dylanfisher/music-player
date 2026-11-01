import Foundation
import Metadata

/// The frame each group is written as. A 2.3 date is split across `TYER`, `TDAT` and `TIME`
/// by `v23DateFrames`.
private func frameID(_ group: TagGroup) -> String {
    switch group {
    case .title: "TIT2"
    case .artist: "TPE1"
    case .album: "TALB"
    case .albumArtist: "TPE2"
    case .genre: "TCON"
    case .date: "TDRC"
    case .composer: "TCOM"
    case .comment: "COMM"
    case .track: "TRCK"
    case .disc: "TPOS"
    case .compilation: "TCMP"
    }
}

/// 2.3 and 2.4's picture frame; the reader also takes 2.2's three-letter one.
private let pictureFrameID = id3PictureFrameIDs.first { $0.count == 4 }!
/// The language a new comment gets when the old one gave none.
private let defaultCommentLanguage = Array("eng".utf8)
/// ID3's picture type for the front cover, which the reader prefers.
let frontCoverPictureType: UInt8 = 3

extension ID3Tag {
    /// Applies `groups` with their values in `tags`, and `art`. `artOffset` is where the reader
    /// found the current art, which picks the picture frame to replace.
    mutating func apply(
        _ groups: [TagGroup], from tags: TrackTags, art: ArtChange?, artOffset: Int?
    ) throws(ParseFailure) {
        if let art { try applyArt(art, artOffset: artOffset) }
        for group in groups {
            let ids = Set(group.readerFields.flatMap { id3FrameIDs(for: $0) })
            let replaced: (ID3Frame) -> Bool =
                group == .comment
                ? { [version] in $0.isUserComment(version: version) } : { ids.contains($0.id) }
            let language =
                group == .comment
                ? frames.first(where: replaced).map { Array($0.body.dropFirst().prefix(3)) }
                : nil
            replace(where: replaced, with: try frames(group, tags, language: language))
        }
    }

    private func frames(_ group: TagGroup, _ tags: TrackTags, language: [UInt8]?)
        throws(ParseFailure) -> [ID3Frame]
    {
        let text = group.isPair ? numberPairText(group.numbers(in: tags)) : group.text(in: tags)
        guard let text else { return [] }
        if group == .date, version == 3 { return try v23DateFrames(text) }
        var body: [UInt8]
        switch group {
        case .comment:
            let encoding = textEncoding(text)
            body = [encoding] + (language ?? defaultCommentLanguage) + terminator(encoding)
            body += encode(text, encoding)
        case .genre:
            // A leading "(" would read as an ID3v1 genre reference; "((" escapes it.
            let escaped = text.hasPrefix("(") ? "(" + text : text
            body = [textEncoding(escaped)] + encode(escaped, textEncoding(escaped))
        default:
            body = [textEncoding(text)] + encode(text, textEncoding(text))
        }
        return [try ID3Frame(id: frameID(group), body: body, version: version)]
    }

    /// "1997", "1997-05-12" or "1997-05-12T14:30" as 2.3's year, DDMM day and HHMM time.
    /// Anything else, a month without a day among them, 2.3 can't hold, so it's refused.
    private func v23DateFrames(_ text: String) throws(ParseFailure) -> [ID3Frame] {
        func digits(_ part: String) -> Bool { part.allSatisfy { $0.isASCII && $0.isNumber } }
        let characters = Array(text)
        func part(_ range: Range<Int>) -> String { String(characters[range]) }
        func frame(_ id: String, _ value: String) throws(ParseFailure) -> ID3Frame {
            try ID3Frame(id: id, body: [0] + Array(value.utf8), version: version)
        }
        let shapes = [4, 10, 16]
        guard shapes.contains(characters.count), digits(part(0..<4)),
            characters.count == 4
                || (characters[4] == "-" && digits(part(5..<7)) && characters[7] == "-"
                    && digits(part(8..<10))),
            characters.count < 16
                || (characters[10] == "T" && digits(part(11..<13)) && characters[13] == ":"
                    && digits(part(14..<16)))
        else {
            throw .unsupported(
                at: nil,
                "ID3v2.3 holds a date as a year, a day and a time; \"\(text)\" doesn't fit")
        }
        var result = [try frame(id3v23YearFrameID, part(0..<4))]
        if characters.count >= 10 {
            result.append(try frame(id3v23DayFrameID, part(8..<10) + part(5..<7)))
        }
        if characters.count == 16 {
            result.append(try frame(id3v23TimeFrameID, part(11..<13) + part(14..<16)))
        }
        return result
    }

    private mutating func applyArt(_ art: ArtChange, artOffset: Int?) throws(ParseFailure) {
        let isPicture = { (frame: ID3Frame) in id3PictureFrameIDs.contains(frame.id) }
        switch art {
        case .remove:
            frames.removeAll(where: isPicture)
        case .replace(let image, let mimeType):
            var body: [UInt8] = [0] + Array(mimeType.utf8) + [0, frontCoverPictureType, 0]
            body += image
            let new = try ID3Frame(id: pictureFrameID, body: body, version: version)
            var cursor = start + Self.headerBytes
            var target: Int?
            for (index, frame) in frames.enumerated() {
                if let artOffset, (cursor..<cursor + frame.raw.count).contains(artOffset) {
                    target = index
                }
                cursor += frame.raw.count
            }
            if let target {
                frames[target] = new
            } else {
                frames.append(new)
            }
        }
    }

    /// Latin-1 for ASCII, which every reader takes; otherwise UTF-8 in 2.4 and UTF-16 in 2.3,
    /// which has no UTF-8.
    private func textEncoding(_ text: String) -> UInt8 {
        if text.unicodeScalars.allSatisfy(\.isASCII) { return 0 }
        return version == 4 ? 3 : 1
    }

    private func terminator(_ encoding: UInt8) -> [UInt8] { encoding == 1 ? [0, 0] : [0] }

    private func encode(_ text: String, _ encoding: UInt8) -> [UInt8] {
        switch encoding {
        case 1: [0xFF, 0xFE] + text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        default: Array(text.utf8)
        }
    }
}
