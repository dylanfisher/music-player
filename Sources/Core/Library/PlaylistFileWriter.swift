import Foundation

/// What an M3U8 line pair says about one track.
public struct PlaylistFileTrack: Equatable, Sendable {
    public var path: String
    public var durationSeconds: Double
    public var artist: String?
    public var title: String

    public init(path: String, durationSeconds: Double, artist: String?, title: String) {
        self.path = path
        self.durationSeconds = durationSeconds
        self.artist = artist
        self.title = title
    }

    init(_ row: TrackRow) {
        self.init(
            path: row.path, durationSeconds: row.durationSeconds, artist: row.artist,
            title: row.title)
    }
}

/// `tracks` as M3U8: `#EXTM3U`, then `#EXTINF:<seconds>,<artist> - <title>` and the path for
/// each, LF-ended. Paths are NFC, which other systems and players expect (ADR 0032), and
/// relative to `folder` when it's given. A path holding a line break or a NUL, or longer than
/// a line the reader takes, isn't written and is returned in `unwritable`.
public func m3u8Bytes(_ tracks: [PlaylistFileTrack], relativeTo folder: String?)
    -> (bytes: [UInt8], unwritable: [String])
{
    var text = "#EXTM3U\n"
    var unwritable: [String] = []
    let base = folder.map { components(folded($0.precomposedStringWithCanonicalMapping)) }
    for track in tracks {
        let path = folded(track.path.precomposedStringWithCanonicalMapping)
        let line = base.map { relative(path, to: $0) } ?? path
        // Scalars, not characters: CRLF is one character, and a NUL can carry a combining mark.
        guard track.path.hasPrefix("/"),
            !line.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }),
            line.utf8.count <= PlaylistFile.maximumLineBytes
        else {
            unwritable.append(track.path)
            continue
        }
        // M3U's -1 is a length not known; a day or more from a broken file is as good as that.
        let seconds =
            (0..<86_400).contains(track.durationSeconds)
            ? Int(track.durationSeconds.rounded()) : -1
        let name = track.artist.map { "\($0) - \(track.title)" } ?? track.title
        text += "#EXTINF:\(seconds),\(oneLine(name))\n\(line)\n"
    }
    return (Array(text.utf8), unwritable)
}

/// Writes `tracks` as M3U8 to `url`, replacing what's there in one rename, and returns the
/// paths it couldn't write.
func writeM3U8(_ tracks: [PlaylistFileTrack], to url: URL, relativePaths: Bool) throws
    -> [String]
{
    let (bytes, unwritable) = m3u8Bytes(
        tracks, relativeTo: relativePaths ? url.deletingLastPathComponent().path : nil)
    try Data(bytes).write(to: url, options: .atomic)
    return unwritable
}

private func components(_ path: String) -> [Substring] {
    path.split(separator: "/", omittingEmptySubsequences: true)
}

/// `path` from the folder `base`, with `..` for each folder of `base` it isn't in. A result the
/// reader would take for a comment, a blank line or a URL starts with `./`.
private func relative(_ path: String, to base: [Substring]) -> String {
    let parts = components(path)
    var shared = 0
    while shared < min(parts.count, base.count), parts[shared] == base[shared] { shared += 1 }
    let text =
        (Array(repeating: "..", count: base.count - shared) + parts[shared...].map(String.init))
        .joined(separator: "/")
    if text.hasPrefix("#") || text.allSatisfy(\.isWhitespace)
        || PlaylistEntry(text[...]) != .relative(text)
    {
        return "./" + text
    }
    return text
}

/// Tag text on one line: each line break or other control becomes a space.
private func oneLine(_ text: String) -> String {
    String(
        text.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : Character($0) })
}
