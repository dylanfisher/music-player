import Foundation
import Metadata

/// The frame each group is written as, in 2.3 and 2.4. 2.3 has no `TDRC`; its `TYER` holds only
/// a year, so other dates go in `TDRC`, which the reader takes in either version.
private func frameID(_ group: TagGroup, version: UInt8, text: String) -> String {
    switch group {
    case .title: "TIT2"
    case .artist: "TPE1"
    case .album: "TALB"
    case .albumArtist: "TPE2"
    case .genre: "TCON"
    case .date:
        version == 3 && text.count == 4 && text.allSatisfy({ $0.isASCII && $0.isNumber })
            ? "TYER" : "TDRC"
    case .composer: "TCOM"
    case .comment: "COMM"
    case .track: "TRCK"
    case .disc: "TPOS"
    case .compilation: "TCMP"
    }
}

private let pictureFrameID = "APIC"
/// The language a new comment gets when the old one gave none.
private let defaultCommentLanguage = Array("eng".utf8)
/// ID3's picture type for the front cover, which the reader prefers.
let frontCoverPictureType: UInt8 = 3

extension ID3Tag {
    /// Applies `groups` with their values in `tags`, and `art`. `artOffset` is where the reader
    /// found the current art, which picks the picture frame to replace.
    mutating func apply(
        _ groups: [TagGroup], from tags: TrackTags, art: ArtChange?, artOffset: Int?
    ) {
        if let art { applyArt(art, artOffset: artOffset) }
        for group in groups {
            let ids = Set(group.readerFields.flatMap { id3FrameIDs(for: $0) })
            let replaced: (ID3Frame) -> Bool =
                group == .comment
                ? { $0.isUserComment } : { ids.contains($0.id) }
            let language =
                group == .comment
                ? frames.first(where: replaced).map { Array($0.body.dropFirst().prefix(3)) }
                : nil
            replace(
                where: replaced, with: frame(group, tags, language: language).map { [$0] } ?? [])
        }
    }

    private func frame(_ group: TagGroup, _ tags: TrackTags, language: [UInt8]?) -> ID3Frame? {
        let text = group.isPair ? numberPairText(group.numbers(in: tags)) : group.text(in: tags)
        guard let text else { return nil }
        let id = frameID(group, version: version, text: text)
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
        return ID3Frame(id: id, body: body, version: version)
    }

    private mutating func applyArt(_ art: ArtChange, artOffset: Int?) {
        let isPicture = { (frame: ID3Frame) in id3PictureFrameIDs.contains(frame.id) }
        switch art {
        case .remove:
            frames.removeAll(where: isPicture)
        case .replace(let image, let mimeType):
            var body: [UInt8] = [0] + Array(mimeType.utf8) + [0, frontCoverPictureType, 0]
            body += image
            let new = ID3Frame(id: pictureFrameID, body: body, version: version)
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
