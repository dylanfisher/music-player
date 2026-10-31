import AudioToolbox
import Foundation
import Testing

@testable import Fixtures

/// Big enough that the plan uses every seed and tag layout, small enough to build in a second.
private let libraryCount = 1000

/// One library shared by the tests that only read it.
private let library = Result { () throws -> (URL, FixtureManifest) in
    let root = temporaryDirectory()
    #expect(try generateFixtures(count: libraryCount, in: root) == .generated)
    return (root, try loadManifest(in: root))
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("fixtures-\(UUID().uuidString)")
}

private func open(_ url: URL) throws -> ExtAudioFileRef {
    var file: ExtAudioFileRef?
    let status = ExtAudioFileOpenURL(url as CFURL, &file)
    guard status == noErr, let file else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
    }
    return file
}

/// The file's audio decoded to 32-bit integers, with its format and length as AudioToolbox
/// reports them.
private func decode(_ url: URL) throws -> (
    format: AudioStreamBasicDescription, frames: Int64, samples: [Int32]
) {
    let file = try open(url)
    defer { ExtAudioFileDispose(file) }
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout.size(ofValue: format))
    #expect(
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format) == noErr
    )
    var frames: Int64 = 0
    size = UInt32(MemoryLayout.size(ofValue: frames))
    #expect(
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames)
            == noErr)

    let channels = format.mChannelsPerFrame
    var client = AudioStreamBasicDescription(
        mSampleRate: format.mSampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
        mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    #expect(
        ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout.size(ofValue: client)),
            &client) == noErr)
    var samples = [Int32](repeating: 0, count: Int(frames + 4096) * Int(channels))
    var read = UInt32(frames + 4096)
    try samples.withUnsafeMutableBytes { bytes in
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: channels, mDataByteSize: UInt32(bytes.count),
                mData: bytes.baseAddress))
        guard ExtAudioFileRead(file, &read, &list) == noErr else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
    return (format, frames, Array(samples.prefix(Int(read) * Int(channels))))
}

/// Tags as AudioToolbox's own parsers read them, an independent check that the blocks are valid.
private func audioToolboxTags(_ url: URL) throws -> (info: [String: Any], artBytes: Int?) {
    var file: AudioFileID?
    #expect(AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr)
    defer { AudioFileClose(file!) }
    var info: Unmanaged<CFDictionary>?
    var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
    #expect(AudioFileGetProperty(file!, kAudioFilePropertyInfoDictionary, &size, &info) == noErr)
    var art: Unmanaged<CFData>?
    size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
    let artStatus = AudioFileGetProperty(file!, kAudioFilePropertyAlbumArtwork, &size, &art)
    return (
        info!.takeRetainedValue() as! [String: Any],
        artStatus == noErr ? art.map { CFDataGetLength($0.takeRetainedValue()) } : nil
    )
}

@Test func manifestMatchesTheFilesOnDisk() throws {
    let (root, manifest) = try library.get()
    #expect(manifest.fileCount == libraryCount)
    #expect(manifest.files.count == libraryCount)
    #expect(manifest.files.map(\.path) == manifest.files.map(\.path).sorted())
    for file in manifest.files {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent(file.path).path)
        #expect(attributes[.size] as? Int == file.byteCount, "\(file.path)")
    }
}

@Test func coversEverySeedTagFormatAndMalformation() throws {
    let (_, manifest) = try library.get()
    let audio = Set(
        manifest.files.compactMap(\.audio).map { "\($0.codec) \($0.sampleRateHz) \($0.channels)" })
    #expect(audio.count == SeedKind.allCases.count - 1)  // the two 44.1 kHz PCM seeds look alike
    #expect(
        Set(manifest.files.flatMap(\.tagFormats))
            == [.vorbisComment, .mp4, .id3v22, .id3v23, .id3v24, .riffInfo])
    #expect(Set(manifest.files.compactMap(\.malformation)) == Set(Malformation.allCases))
    #expect(manifest.files.contains { $0.art?.mimeType == "image/png" })
    #expect(manifest.files.contains { $0.tags?.compilation == true })
    #expect(manifest.files.contains { $0.audio != nil && $0.tags == nil })
}

@Test func everyValidFileDecodesToItsSeedsAudio() throws {
    let (root, manifest) = try library.get()
    var audioBySeed: [String: [Int32]] = [:]
    for file in manifest.files {
        guard let expected = file.audio else { continue }
        let decoded = try decode(root.appendingPathComponent(file.path))
        #expect(decoded.format.mSampleRate == Double(expected.sampleRateHz), "\(file.path)")
        #expect(decoded.format.mChannelsPerFrame == UInt32(expected.channels), "\(file.path)")
        #expect(decoded.frames == Int64(expected.lengthFrames), "\(file.path)")
        // Same seed, different tags: the audio must come out identical, which catches a bad
        // splice or a wrong MP4 chunk offset.
        let seed = "\(file.container) \(expected)"
        if let first = audioBySeed[seed] {
            #expect(decoded.samples == first, "\(file.path)")
        } else {
            audioBySeed[seed] = decoded.samples
        }
    }
}

@Test func audioToolboxReadsTheTagsBack() throws {
    let (root, manifest) = try library.get()
    for file in manifest.files where file.malformation == nil {
        let (info, artBytes) = try audioToolboxTags(root.appendingPathComponent(file.path))
        // AudioToolbox reads INFO text as Latin-1; the generator writes UTF-8, as most taggers do.
        let readsTitles =
            !file.tagFormats.contains(.riffInfo)
            || [file.tags?.title, file.tags?.artist].allSatisfy {
                $0?.allSatisfy(\.isASCII) ?? true
            }
        if readsTitles {
            #expect(info["title"] as? String == file.tags?.title, "\(file.path)")
            #expect(info["artist"] as? String == file.tags?.artist, "\(file.path)")
        }
        // AudioToolbox doesn't map INFO's album field.
        if file.tagFormats != [.riffInfo] {
            #expect(info["album"] as? String == file.tags?.album, "\(file.path)")
        }
        // It reads embedded art from FLAC and MP4 only.
        if file.container == .flac || file.container == .mp4 {
            #expect(artBytes == file.art?.byteCount, "\(file.path)")
        }
    }
}

@Test func rerunningTheSameCountIsSkipped() throws {
    let root = temporaryDirectory()
    #expect(try generateFixtures(count: 30, in: root) == .generated)
    let manifest = root.appendingPathComponent(FixtureManifest.fileName)
    let written = try FileManager.default.attributesOfItem(atPath: manifest.path)[.modificationDate]
    #expect(try generateFixtures(count: 30, in: root) == .upToDate)
    #expect(
        try FileManager.default.attributesOfItem(atPath: manifest.path)[.modificationDate] as? Date
            == written as? Date)

    #expect(try generateFixtures(count: 30, in: root, force: true) == .generated)
    #expect(try generateFixtures(count: 31, in: root) == .generated)
    #expect(try loadManifest(in: root).files.count == 31)
}

@Test func aMissingFileMakesTheLibraryStale() throws {
    let root = temporaryDirectory()
    #expect(try generateFixtures(count: 30, in: root) == .generated)
    let victim = try loadManifest(in: root).files[0].path
    try FileManager.default.removeItem(at: root.appendingPathComponent(victim))
    #expect(try generateFixtures(count: 30, in: root) == .generated)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(victim).path))
}

@Test func refusesToClearADirectoryItDidntWrite() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let keep = root.appendingPathComponent("song.flac")
    try Data("not ours".utf8).write(to: keep)
    #expect(throws: FixtureError.self) { try generateFixtures(count: 5, in: root) }
    #expect(FileManager.default.fileExists(atPath: keep.path))
}

@Test func planIsDeterministic() {
    let first = planLibrary(count: 500)
    let second = planLibrary(count: 500)
    #expect(first.map(\.path) == second.map(\.path))
    #expect(first.map(\.tags) == second.map(\.tags))
    #expect(Set(first.map(\.path)).count == first.count)
}

@Test func writesSyncsafeIntegers() {
    var data = Data()
    data.appendSyncsafe(0x0FFF_FFFF)
    data.appendSyncsafe(257)
    #expect(data == Data([0x7F, 0x7F, 0x7F, 0x7F, 0x00, 0x00, 0x02, 0x01]))
}
