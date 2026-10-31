import Foundation
import HALOutput
import Library
import Metadata

/// A file to play and what to show for it.
struct QueuedFile {
    var url: URL
    /// "Artist – Title" from its tags, or the file name.
    var name: String
    /// "96 kHz 24-bit flac" from its container, or nil when its tags didn't read.
    var format: String?

    init(_ url: URL, _ metadata: TrackMetadata?) {
        self.url = url
        if let title = metadata?.tags.title {
            name = metadata?.tags.artist.map { "\($0) – \(title)" } ?? title
        } else {
            name = url.lastPathComponent
        }
        format = metadata.map { metadata in
            let audio = metadata.audio
            let bits = audio.bitsPerSample.map { " \($0)-bit" } ?? ""
            return "\(kilohertz(Double(audio.sampleRateHz))) kHz\(bits) \(audio.codec.rawValue)"
        }
    }
}

/// The files `--play` was given, in order. A folder contributes its audio files, folder by folder
/// in name order, and within each folder by disc and track number from the tags, then by file
/// name. A file whose tags don't read is still queued, sorted by name, and reported in `warnings`.
func queuedFiles(_ paths: [String]) throws -> (files: [QueuedFile], warnings: [String]) {
    var files: [QueuedFile] = []
    var warnings: [String] = []
    for path in paths {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw PlayCommandError.missing(path)
        }
        guard isDirectory.boolValue else {
            files.append(QueuedFile(url, metadata(of: url, &warnings)))
            continue
        }
        let found = try audioFiles(in: url)
        if found.isEmpty { warnings.append("\(path) has no audio files") }
        let byFolder = Dictionary(grouping: found) { $0.deletingLastPathComponent().path }
        for folder in byFolder.keys.sorted(by: {
            $0.localizedStandardCompare($1) == .orderedAscending
        }) {
            let read = byFolder[folder]!.map { ($0, metadata(of: $0, &warnings)) }
            files += read.sorted(by: albumOrder).map { QueuedFile($0, $1) }
        }
    }
    return (files, warnings)
}

private func audioFiles(in folder: URL) throws -> [URL] {
    // Hidden files include the "._" AppleDouble files macOS leaves on SMB shares.
    guard
        let walk = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
    else { throw PlayCommandError.unlistable(folder.path) }
    var files: [URL] = []
    for case let url as URL in walk
    where audioFileExtensions.contains(url.pathExtension.lowercased()) {
        files.append(url)
    }
    return files
}

private func metadata(of url: URL, _ warnings: inout [String]) -> TrackMetadata? {
    do {
        return try readMetadata(at: url).metadata
    } catch {
        warnings.append("\(url.path): \(error); ordering it by file name")
        return nil
    }
}

private func albumOrder(_ a: (URL, TrackMetadata?), _ b: (URL, TrackMetadata?)) -> Bool {
    func key(_ metadata: TrackMetadata?) -> (Int, Int) {
        (metadata?.tags.discNumber ?? 0, metadata?.tags.trackNumber ?? Int.max)
    }
    let (left, right) = (key(a.1), key(b.1))
    if left != right { return left < right }
    return a.0.lastPathComponent.localizedStandardCompare(b.0.lastPathComponent)
        == .orderedAscending
}
