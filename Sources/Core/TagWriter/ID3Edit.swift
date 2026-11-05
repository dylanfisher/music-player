import Foundation
import Metadata

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
            var replaced = { [version] (frame: ID3Frame) in frame.group(version: version) == group }
            var writtenID: String?
            // iTunes's grouping frame wins over `TIT1` and leaves `TIT1` to the work, so an edit
            // of a tag that has one stays in it.
            if group == .text(.grouping),
                frames.contains(where: { $0.id == ID3FrameID.iTunesGrouping })
            {
                replaced = { $0.id == ID3FrameID.iTunesGrouping }
                writtenID = ID3FrameID.iTunesGrouping
            }
            let language = frames.first(where: replaced).flatMap { [version] frame in
                frame.isUndescribed(version: version)
                    ? Array(frame.body.dropFirst().prefix(3)) : nil
            }
            replace(
                where: replaced,
                with: try frames(group, tags, language: language, writtenID: writtenID))
        }
    }

    private func frames(
        _ group: TagGroup, _ tags: TrackTags, language: [UInt8]?, writtenID: String?
    ) throws(ParseFailure) -> [ID3Frame] {
        let text = group.isPair ? numberPairText(group.numbers(in: tags)) : group.text(in: tags)
        guard let text else { return [] }
        if group == .text(.date), version == 3 { return try v23DateFrames(text) }
        let field = group.readerFields[0]
        guard var key = id3WrittenKey(for: field, version: version) else {
            preconditionFailure("\(field) has no ID3 frame")
        }
        if group == .text(.originalDate), version == 3, text.count == 4,
            text.allSatisfy({ $0.isASCII && $0.isNumber })
        {
            key = .text(id3v23OriginalYearFrameID)
        }
        if let writtenID { key = .text(writtenID) }
        switch key {
        case .text(let id):
            // A leading "(" would read as an ID3v1 genre reference; "((" escapes it.
            let value = group == .text(.genre) && text.hasPrefix("(") ? "(" + text : text
            let encoding = textEncoding(value)
            return [
                try ID3Frame(id: id, body: [encoding] + encode(value, encoding), version: version)
            ]
        case .userText(let description):
            let encoding = textEncoding(description + text)
            let body =
                [encoding] + encode(description, encoding) + terminator(encoding)
                + encode(text, encoding)
            return [try ID3Frame(id: id3UserTextFrameID, body: body, version: version)]
        case .described(let id):
            let encoding = textEncoding(text)
            var body = [encoding] + (language ?? defaultCommentLanguage) + terminator(encoding)
            body += encode(text, encoding)
            return [try ID3Frame(id: id, body: body, version: version)]
        case .url(let id):
            guard text.unicodeScalars.allSatisfy({ $0.value < 0x100 }) else {
                throw .unsupported(
                    at: nil, "an ID3 URL frame holds Latin-1 text only; \"\(text)\" doesn't fit")
            }
            let body = text.unicodeScalars.map { UInt8($0.value) }
            return [try ID3Frame(id: id, body: body, version: version)]
        }
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
