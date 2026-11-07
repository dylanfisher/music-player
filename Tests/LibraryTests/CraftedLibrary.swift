import Foundation
import Testing

@testable import Library
@testable import Metadata
@testable import Settings

/// One crafted track's tags and audio, stored without a file behind it.
struct Crafted {
    var path: String
    var title: String? = nil
    var artist: String? = "Artist"
    var album: String? = nil
    var albumArtist: String? = nil
    var disc: Int? = nil
    var number: Int? = nil
    var seconds = 200.0
    var rateHz = 44100
    var art = true
    var warning = false
    var custom: [String: String] = [:]
    var label: String? = nil
    var catalogNumber: String? = nil
    var barcode: String? = nil

    var scanned: ScannedFile {
        var tags = TrackTags()
        tags.title = title
        tags.artist = artist
        tags.album = album
        tags.albumArtist = albumArtist
        tags.discNumber = disc
        tags.trackNumber = number
        tags.custom = custom
        tags.publisher = label
        tags.catalogNumber = catalogNumber
        tags.barcode = barcode
        let audio = TrackAudio(
            codec: .flac, sampleRateHz: rateHz, bitsPerSample: 16, channels: 2,
            lengthFrames: Int(seconds * Double(rateHz)))
        let metadata = TrackMetadata(
            tags: tags, audio: audio,
            art: art
                ? EmbeddedArt(
                    offset: 10, byteCount: 10, mimeType: "image/jpeg", unsynchronised: false)
                : nil)
        let warnings =
            warning ? [MetadataWarning(kind: .badNumber, offset: 4, detail: "track \"1x\"")] : []
        return ScannedFile(
            path: path, sizeBytes: 1, modifiedSeconds: 1, known: nil,
            outcome: .success(
                ParsedFile(metadata: metadata, warnings: warnings, bytesRead: 0, readCount: 0)))
    }
}

/// A file the scanner couldn't read.
func failed(_ path: String) -> ScannedFile {
    ScannedFile(
        path: path, sizeBytes: 1, modifiedSeconds: 1, known: nil,
        outcome: .failure(
            MetadataError(path: path, kind: .malformed, offset: 8, detail: "no header")))
}

/// An index in a fresh temporary folder holding `files`.
func craftedIndex(_ files: [ScannedFile]) throws -> LibraryIndex {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("crafted-\(UUID().uuidString)")
    let index = try LibraryIndex(at: directory.appendingPathComponent("library.sqlite"))
    try index.store(files)
    return index
}

/// The IDs of the tracks at `paths`.
func ids(_ index: LibraryIndex, _ paths: [String]) throws -> [Int64] {
    try paths.map { try #require(try index.track(path: $0)).id }.sorted()
}
