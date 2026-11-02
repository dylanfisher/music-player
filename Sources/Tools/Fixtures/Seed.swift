import Foundation

/// The tiny real files every fixture is cloned from: one per codec, rate and bit depth.
enum SeedKind: String, CaseIterable, Sendable {
    case flac16, flac24x96, flac24x192, alac16, alac24x96, aac, wav16, wav24x96, aiff16
    case aiff24Mono, mp3

    var container: FixtureFile.Container {
        switch self {
        case .flac16, .flac24x96, .flac24x192: .flac
        case .alac16, .alac24x96, .aac: .mp4
        case .wav16, .wav24x96: .wav
        case .aiff16, .aiff24Mono: .aiff
        case .mp3: .mp3
        }
    }

    var fileExtension: String {
        switch container {
        case .flac: "flac"
        case .mp4: "m4a"
        case .mp3: "mp3"
        case .wav: "wav"
        case .aiff: "aiff"
        }
    }

    /// The source's format. Lossy seeds encode a 16-bit source.
    var audio: AudioProperties {
        let (codec, rate, bits, channels): (FixtureFile.Codec, Int, Int?, Int) =
            switch self {
            case .flac16: (.flac, 44_100, 16, 2)
            case .flac24x96: (.flac, 96_000, 24, 2)
            case .flac24x192: (.flac, 192_000, 24, 2)
            case .alac16: (.alac, 44_100, 16, 2)
            case .alac24x96: (.alac, 96_000, 24, 2)
            case .aac: (.aac, 44_100, nil, 2)
            case .wav16: (.pcm, 44_100, 16, 2)
            case .wav24x96: (.pcm, 96_000, 24, 2)
            case .aiff16: (.pcm, 44_100, 16, 2)
            case .aiff24Mono: (.pcm, 48_000, 24, 1)
            case .mp3: (.mp3, 44_100, nil, 2)
            }
        let length = self == .mp3 ? mp3FrameCount * mp3SamplesPerFrame : rate / 10
        return AudioProperties(
            codec: codec, sampleRateHz: rate, bitsPerSample: bits, channels: channels,
            lengthFrames: length)
    }

    /// Nil for MP3, which macOS can't encode.
    var afconvertArguments: [String]? {
        switch self {
        // FLAC writes no audio when the file is shorter than one packet, and its default packet
        // is 4608 frames, longer than 0.1 s at 44.1 kHz.
        case .flac16, .flac24x96, .flac24x192: ["-f", "flac", "-d", "flac#4096"]
        case .alac16, .alac24x96: ["-f", "m4af", "-d", "alac"]
        case .aac: ["-f", "m4af", "-d", "aac"]
        case .wav16: ["--no-filler", "-f", "WAVE", "-d", "LEI16"]
        case .wav24x96: ["--no-filler", "-f", "WAVE", "-d", "LEI24"]
        case .aiff16: ["--no-filler", "-f", "AIFF", "-d", "BEI16"]
        case .aiff24Mono: ["--no-filler", "-f", "AIFF", "-d", "BEI24"]
        case .mp3: nil
        }
    }
}

/// A seed split into the parts the tag writers put back together around new tags.
enum Seed: Sendable {
    case flac(streamInfo: Data, frames: Data)
    case mp4(MP4Seed)
    case mp3(frames: Data)
    /// Every chunk except tags, each with its header and pad byte.
    case wav(chunks: Data)
    case aiff(chunks: Data)
}

/// Encodes every seed with afconvert in `directory` and splits it into parts.
func makeSeeds(in directory: URL) throws -> [SeedKind: Seed] {
    let kinds = SeedKind.allCases
    let results = LockedArray<Result<Seed, any Error>?>(repeating: nil, count: kinds.count)
    DispatchQueue.concurrentPerform(iterations: kinds.count) { index in
        results[index] = Result { try makeSeed(kinds[index], in: directory) }
    }
    return Dictionary(
        uniqueKeysWithValues: try zip(kinds, results.values).map { ($0, try $1!.get()) })
}

private func makeSeed(_ kind: SeedKind, in directory: URL) throws -> Seed {
    let audio = kind.audio
    guard let arguments = kind.afconvertArguments else {
        return .mp3(frames: silentMP3Frames())
    }
    let source = directory.appendingPathComponent("\(kind.rawValue)-source.wav")
    let encoded = directory.appendingPathComponent("\(kind.rawValue).\(kind.fileExtension)")
    try toneWAV(audio).write(to: source)
    try runAfconvert(arguments + [source.path, encoded.path])
    let data = try Data(contentsOf: encoded)
    switch kind.container {
    case .flac: return try splitFLAC(data)
    case .mp4: return .mp4(try MP4Seed(data))
    case .wav:
        return .wav(
            chunks: try riffChunks(data, form: "RIFF", type: "WAVE", keep: ["fmt ", "data"]))
    case .aiff:
        return .aiff(
            chunks: try riffChunks(data, form: "FORM", type: "AIFF", keep: ["COMM", "SSND"]))
    case .mp3: preconditionFailure("MP3 seeds are built without afconvert")
    }
}

func runAfconvert(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert", isDirectory: false)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw FixtureError.afconvertFailed(
            arguments: arguments, status: process.terminationStatus, output: text)
    }
}

/// 0.1 s of a quiet sine per channel as PCM WAV, quiet so it compresses well.
private func toneWAV(_ audio: AudioProperties) -> Data {
    let bits = audio.bitsPerSample ?? 16
    let bytesPerSample = bits / 8
    let frames = audio.sampleRateHz / 10
    let peak = 0.05 * Double((1 << (bits - 1)) - 1)
    var samples = Data(capacity: frames * audio.channels * bytesPerSample)
    for frame in 0..<frames {
        for channel in 0..<audio.channels {
            let hertz = 440.0 + 220.0 * Double(channel)
            let value = Int32(
                peak * sin(2 * .pi * hertz * Double(frame) / Double(audio.sampleRateHz)))
            withUnsafeBytes(of: value.littleEndian) {
                samples.append(contentsOf: $0.prefix(bytesPerSample))
            }
        }
    }
    var format = Data()
    format.appendLittleEndian(UInt16(1))  // integer PCM
    format.appendLittleEndian(UInt16(audio.channels))
    format.appendLittleEndian(UInt32(audio.sampleRateHz))
    format.appendLittleEndian(UInt32(audio.sampleRateHz * audio.channels * bytesPerSample))
    format.appendLittleEndian(UInt16(audio.channels * bytesPerSample))
    format.appendLittleEndian(UInt16(bits))
    return riffForm(
        "WAVE", chunks: riffChunk("fmt ", format, .little) + riffChunk("data", samples, .little),
        .little)
}

let mp3FrameCount = 10
let mp3SamplesPerFrame = 1152

/// MPEG-1 Layer III frames of digital silence: a header, then side info and main data that are
/// all zero, which decodes as zero samples. Built by hand because macOS has no MP3 encoder.
private func silentMP3Frames() -> Data {
    // Sync, MPEG-1, Layer III, no CRC; 128 kbit/s, 44.1 kHz, no padding; stereo.
    let header: [UInt8] = [0xFF, 0xFB, 0x90, 0x00]
    let frameBytes = 144 * 128_000 / 44_100
    var frame = Data(header)
    frame.append(Data(count: frameBytes - header.count))
    var frames = Data()
    for _ in 0..<mp3FrameCount { frames.append(frame) }
    return frames
}

private func splitFLAC(_ data: Data) throws -> Seed {
    guard data.prefix(4) == Data("fLaC".utf8) else {
        throw FixtureError.unexpectedSeed("FLAC without the fLaC marker")
    }
    var offset = 4
    var streamInfo: Data?
    while true {
        guard offset + 4 <= data.count else {
            throw FixtureError.unexpectedSeed("FLAC metadata runs past the end")
        }
        let header = data[offset]
        let length = Int(data.readBigEndianUInt32(at: offset) & 0xFF_FFFF)
        if header & 0x7F == 0 { streamInfo = data[(offset + 4)..<(offset + 4 + length)] }
        offset += 4 + length
        if header & 0x80 != 0 { break }
    }
    guard let streamInfo, offset < data.count else {
        throw FixtureError.unexpectedSeed("FLAC without STREAMINFO or audio frames")
    }
    return .flac(streamInfo: Data(streamInfo), frames: Data(data[offset...]))
}

/// The chunks of a RIFF (little-endian) or AIFF (big-endian) file whose IDs are in `keep`.
private func riffChunks(_ data: Data, form: String, type: String, keep: Set<String>) throws -> Data
{
    guard data.count >= 12, data.prefix(4) == Data(form.utf8), data[8..<12] == Data(type.utf8)
    else { throw FixtureError.unexpectedSeed("not a \(form)/\(type) file") }
    var offset = 12
    var kept = Data()
    while offset + 8 <= data.count {
        let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
        let size = Int(
            form == "RIFF"
                ? data.readLittleEndianUInt32(at: offset + 4)
                : data.readBigEndianUInt32(at: offset + 4))
        let end = offset + 8 + size + (size & 1)
        guard end <= data.count else {
            throw FixtureError.unexpectedSeed("\(id) chunk runs past the end")
        }
        if keep.contains(id) { kept.append(data[offset..<end]) }
        offset = end
    }
    return kept
}
