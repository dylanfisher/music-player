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
            var replaced = { [version] (frame: ID3Frame) in
                frame.group(version: version)?.isReplaced(by: group) == true
            }
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
        if let name = group.customName, ID3CustomKey.isID3Only(name) {
            return [try id3OnlyFrame(name, text)]
        }
        var key: ID3Key
        if let name = group.customName {
            key = .userText(name)
        } else {
            let field = group.readerFields[0]
            guard let written = id3WrittenKey(for: field, version: version) else {
                preconditionFailure("\(field) has no ID3 frame")
            }
            key = written
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

    /// A `WXXX` frame, or the involved people list with its roles and names split at
    /// `ID3CustomKey.involvedPeopleSeparator`, which must leave them in pairs.
    private func id3OnlyFrame(_ name: String, _ text: String) throws(ParseFailure) -> ID3Frame {
        if let description = ID3CustomKey.urlDescription(name) {
            guard text.unicodeScalars.allSatisfy({ $0.value < 0x100 }) else {
                throw .unsupported(
                    at: nil, "an ID3 URL frame holds Latin-1 text only; \"\(text)\" doesn't fit")
            }
            let encoding = textEncoding(description)
            let body =
                [encoding] + encode(description, encoding) + terminator(encoding)
                + text.unicodeScalars.map { UInt8($0.value) }
            return try ID3Frame(id: id3UserURLFrameID, body: body, version: version)
        }
        let values = text.components(separatedBy: ID3CustomKey.involvedPeopleSeparator)
        guard values.count.isMultiple(of: 2) else {
            throw .unsupported(
                at: nil,
                "an ID3 involved people list holds roles and names in pairs; \"\(text)\" has"
                    + " \(values.count) values")
        }
        let encoding = textEncoding(text)
        var body = [encoding]
        for (index, value) in values.enumerated() {
            if index > 0 { body += terminator(encoding) }
            body += encode(value, encoding)
        }
        return try ID3Frame(
            id: id3InvolvedPeopleFrameID(version: version), body: body, version: version)
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
        case .pictures(let pictures):
            // The frames before the first picture stay before them.
            let first = frames.firstIndex(where: isPicture) ?? frames.count
            frames.removeAll(where: isPicture)
            frames.insert(contentsOf: try pictureFrames(pictures), at: first)
        }
    }

    /// A picture frame each, with a description of its own, since ID3 allows one picture a
    /// description: none for the first, as a single cover has, and the type's name for the
    /// rest, numbered from 2 when it repeats.
    private func pictureFrames(_ pictures: [ArtPicture]) throws(ParseFailure) -> [ID3Frame] {
        var used: Set<String> = []
        var frames: [ID3Frame] = []
        for (index, picture) in pictures.enumerated() {
            let name = picture.type.name
            var description = index == 0 ? "" : name
            var number = 1
            while !used.insert(description).inserted {
                number += 1
                description = "\(name) \(number)"
            }
            let encoding = textEncoding(description)
            var body: [UInt8] =
                [encoding] + Array(picture.mimeType.utf8)
                + [0, UInt8(clamping: picture.type.rawValue)] + encode(description, encoding)
                + terminator(encoding)
            body += picture.image
            frames.append(try ID3Frame(id: pictureFrameID, body: body, version: version))
        }
        return frames
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
