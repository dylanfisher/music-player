import AudioToolbox
import Foundation
import ImageIO
import Testing

@testable import Fixtures
@testable import Metadata

/// A library of its own, apart from FixturesTests' copy, because the two test targets run in one
/// process and would otherwise generate into the same directory at once.
private let library = Result { () throws -> (URL, FixtureManifest) in
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/metadata-tests")
    _ = try generateFixtures(count: coveringLibraryFileCount, in: root)
    return (root, try loadManifest(in: root))
}

/// The manifest's tags in the parser's shape. The fixtures write no composer.
private func expectedTags(_ file: FixtureFile) -> TrackTags {
    guard let tags = file.tags else { return TrackTags() }
    return TrackTags(
        title: tags.title, artist: tags.artist, album: tags.album, albumArtist: tags.albumArtist,
        genre: tags.genre, date: tags.date, trackNumber: tags.trackNumber,
        trackTotal: tags.trackTotal, discNumber: tags.discNumber, discTotal: tags.discTotal,
        compilation: tags.compilation, comment: tags.comment)
}

private func expectedAudio(_ audio: AudioProperties) -> TrackAudio? {
    TrackAudio.Codec(rawValue: audio.codec.rawValue).map {
        TrackAudio(
            codec: $0, sampleRateHz: audio.sampleRateHz, bitsPerSample: audio.bitsPerSample,
            channels: audio.channels, lengthFrames: audio.lengthFrames)
    }
}

/// What reading a broken fixture must do: nil when it parses, because the damage is in audio
/// that tag reading never touches.
private func expectedFailure(_ malformation: Malformation) -> MetadataError.Kind? {
    switch malformation {
    case .truncated: nil
    case .empty, .garbage: .unrecognizedFormat
    case .flacBlockPastEnd, .vorbisCommentPastBlock, .id3TagPastEnd, .id3FramePastTag,
        .mp4AtomTooSmall, .mp4AtomPastParent, .riffChunkPastEnd:
        .malformed
    }
}

@Test func everyValidFixtureMatchesItsManifestEntry() throws {
    let (root, manifest) = try library.get()
    for file in manifest.files where file.malformation == nil {
        let parsed = try readMetadata(at: root.appendingPathComponent(file.path))
        let metadata = parsed.metadata
        #expect(metadata.tags == expectedTags(file), "\(file.path)")
        #expect(metadata.audio == file.audio.flatMap(expectedAudio), "\(file.path)")
        #expect(metadata.art?.mimeType == file.art?.mimeType, "\(file.path)")
        #expect(metadata.art?.byteCount == file.art?.byteCount, "\(file.path)")
        #expect(parsed.bytesRead <= file.byteCount, "\(file.path)")
    }
}

@Test func everyMalformedFixtureFailsAsFlagged() throws {
    let (root, manifest) = try library.get()
    for file in manifest.files {
        guard let malformation = file.malformation else { continue }
        let url = root.appendingPathComponent(file.path)
        guard let kind = expectedFailure(malformation) else {
            _ = try readMetadata(at: url)
            continue
        }
        let error = #expect(throws: MetadataError.self, "\(file.path)") {
            try readMetadata(at: url)
        }
        #expect(error?.kind == kind, "\(file.path): \(String(describing: error))")
        #expect(error?.path == url.path)
        if kind == .malformed { #expect(error?.offset != nil, "\(file.path)") }
    }
}

@Test func artReadsBackAsTheImageTheManifestDescribes() throws {
    let (root, manifest) = try library.get()
    for file in manifest.files {
        guard let expected = file.art else { continue }
        let url = root.appendingPathComponent(file.path)
        let art = try #require(try readMetadata(at: url).metadata.art, "\(file.path)")
        let data = try readArt(art, at: url)
        #expect(data.count == expected.byteCount, "\(file.path)")
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties =
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == expected.width, "\(file.path)")
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == expected.height, "\(file.path)")
    }
}

/// AudioToolbox's own parsers, as an independent check of rate, channels and length wherever
/// they read the file, broken fixtures included.
@Test func audioPropertiesAgreeWithAudioToolbox() throws {
    let (root, manifest) = try library.get()
    var compared = 0
    for file in manifest.files {
        let url = root.appendingPathComponent(file.path)
        guard let parsed = try? readMetadata(at: url).metadata.audio else { continue }
        var reference: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &reference) == noErr, let reference else {
            continue
        }
        defer { ExtAudioFileDispose(reference) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        #expect(
            ExtAudioFileGetProperty(reference, kExtAudioFileProperty_FileDataFormat, &size, &format)
                == noErr)
        var frames: Int64 = 0
        size = UInt32(MemoryLayout.size(ofValue: frames))
        #expect(
            ExtAudioFileGetProperty(
                reference, kExtAudioFileProperty_FileLengthFrames, &size, &frames) == noErr)
        #expect(Double(parsed.sampleRateHz) == format.mSampleRate, "\(file.path)")
        #expect(UInt32(parsed.channels) == format.mChannelsPerFrame, "\(file.path)")
        #expect(Int64(parsed.lengthFrames) == frames, "\(file.path)")
        compared += 1
    }
    #expect(compared >= manifest.files.count { $0.malformation == nil })
}
