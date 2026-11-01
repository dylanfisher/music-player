import Foundation
import Metadata

/// The fields whose frame, item or comment in the file at `url` holds several values: an
/// ID3v2.4 text frame with values separated by terminators, an MP4 item with several `data`
/// atoms, or a Vorbis key given more than once. The reader shows the first, and an edit keeps
/// only the value written, so the editor says so before saving.
public func multiValuedFields(at url: URL) throws(MetadataError) -> Set<TagEditField> {
    let file: TagFile
    do throws(ParseFailure) {
        file = try TagFile(path: url.path)
    } catch {
        throw error.error(path: url.path)
    }
    var groups = Set<TagGroup>()
    switch file {
    case .id3(let id3):
        for frame in id3.tag.frames where frame.holdsSeveralValues {
            if let group = TagGroup.of(matching: { id3FrameIDs(for: $0).contains(frame.id) }) {
                groups.insert(group)
            }
        }
    case .mp4(let mp4):
        if let path = mp4.moov.indexPath(MP4File.ilstPath) {
            for item in mp4.moov[path].children ?? [] where dataAtomCount(item) > 1 {
                if let group = TagGroup.of(matching: { mp4ItemTypes(for: $0).contains(item.type) })
                {
                    groups.insert(group)
                }
            }
        }
    case .flac(let flac):
        for block in flac.blocks where block.type == FLACFile.BlockType.vorbisComment.rawValue {
            let comments: [(raw: [UInt8], range: Range<Int>)]
            do throws(ParseFailure) {
                comments = try vorbisComments(block.body, base: 0).comments
            } catch {
                throw error.error(path: url.path)
            }
            var counts: [String: Int] = [:]
            for comment in comments { counts[vorbisKey(comment.raw), default: 0] += 1 }
            for (key, count) in counts where count > 1 {
                if let group = TagGroup.of(matching: { vorbisKeys(for: $0).contains(key) }) {
                    groups.insert(group)
                }
            }
        }
    }
    return Set(groups.flatMap(\.fields))
}

extension ID3Frame {
    /// A text frame whose text holds a terminator before its end: 2.4's separator between
    /// values. Frames with format flags (compressed, unsynchronised) aren't looked into.
    var holdsSeveralValues: Bool {
        guard id.hasPrefix("T"), raw[9] == 0, let encoding = body.first else { return false }
        let wide = encoding == 1 || encoding == 2
        var text = Array(body.dropFirst())
        let width = wide ? 2 : 1
        while text.count >= width, text.suffix(width).allSatisfy({ $0 == 0 }) {
            text.removeLast(width)
        }
        return stride(from: 0, to: text.count - width + 1, by: width).contains { index in
            text[index..<index + width].allSatisfy { $0 == 0 }
        }
    }
}

/// How many `data` atoms an `ilst` item holds.
private func dataAtomCount(_ item: MP4Box) -> Int {
    var count = 0
    var cursor = 0
    while cursor + 8 <= item.body.count {
        let size = Int(bigEndianValue(item.body[cursor..<cursor + 4]))
        guard size >= 8, cursor + size <= item.body.count else { break }
        if item.body[cursor + 4..<cursor + 8].elementsEqual(MP4Type.data.utf8) { count += 1 }
        cursor += size
    }
    return count
}
