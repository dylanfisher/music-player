import Foundation

@testable import Metadata
@testable import TagWriter

/// A text frame of `version`: Latin-1, no flags.
func id3TextFrame(_ id: String, _ text: String, version: UInt8 = 3) -> [UInt8] {
    ID3Frame(id: id, body: [0] + Array(text.utf8), version: version).raw
}

/// An ID3v2 tag of `frames` and `padding`, with `flags` in its header.
func id3Tag(_ frames: [[UInt8]], version: UInt8 = 3, flags: UInt8 = 0, padding: Int = 64)
    -> [UInt8]
{
    let body = frames.flatMap { $0 } + [UInt8](repeating: 0, count: padding)
    return Array("ID3".utf8) + [version, 0, flags] + syncsafeBytes(body.count) + body
}

/// The MP3 sample's audio frames behind a tag of our own.
func mp3(withTag tag: [UInt8]) throws -> URL {
    let url = try Sample.mp3Untagged.copy()
    let audio = try Data(contentsOf: url)
    try (Data(tag) + audio).write(to: url)
    return url
}
