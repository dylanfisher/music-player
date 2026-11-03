import Foundation
import Log

/// `~/Library/Caches/MusicPlayer/playback-fixtures`. The version in the name changes whenever the
/// generated audio does, so a stale cache is never read.
public func defaultPlaybackFixturesDirectory() throws -> URL {
    try FileManager.default.url(
        for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
    ).appendingPathComponent("\(appDirectoryName)/playback-fixtures-v1")
}

/// One continuous ramp split into two FLAC tracks, so any gap, repeat or click at the boundary
/// shows as a sample that isn't the next step of the ramp.
public struct RampAlbum: Sendable {
    public let tracks: [URL]
    let trackFrames: [Int]
    public let sampleRateHz: Int
    public let bitsPerSample: Int

    public var totalFrames: Int { trackFrames.reduce(0, +) }

    /// Frame `index` of the album, as the stereo 32-bit samples a device receives.
    public func frame(_ index: Int) -> (Int32, Int32) {
        let shift = Int32(32 - bitsPerSample)
        return (
            rampSample(index, channel: 0, bits: bitsPerSample) << shift,
            rampSample(index, channel: 1, bits: bitsPerSample) << shift
        )
    }
}

private func rampSample(_ frame: Int, channel: Int, bits: Int) -> Int32 {
    let span = 1 << bits
    return Int32((frame * 7 + channel * 12_345) % span - span / 2)
}

/// Makes the album the first time it's asked for at this rate and depth, and returns it. The
/// first track ends partway through a FLAC block, so the boundary isn't on a convenient frame.
public func rampAlbum(sampleRateHz: Int, bitsPerSample: Int, in directory: URL) throws
    -> RampAlbum
{
    let frames = [sampleRateHz + 123, sampleRateHz / 2]
    var tracks: [URL] = []
    var start = 0
    for (index, count) in frames.enumerated() {
        let url = directory.appendingPathComponent(
            "ramp-\(sampleRateHz)-\(bitsPerSample)-\(index + 1).flac")
        let first = start
        try makeEncoded(
            at: url, sampleRateHz: sampleRateHz, bitsPerSample: bitsPerSample, frames: count
        ) { frame, channel in
            rampSample(first + frame, channel: channel, bits: bitsPerSample)
        }
        tracks.append(url)
        start += count
    }
    return RampAlbum(
        tracks: tracks, trackFrames: frames, sampleRateHz: sampleRateHz,
        bitsPerSample: bitsPerSample)
}

/// One continuous sine, a different phase on each channel, split into two FLAC tracks as a
/// `RampAlbum` is, for output that resamples: a ramp's steps would ring, but any gap, repeat or
/// seam at the join still shows as samples off the sine.
public struct SineAlbum: Sendable {
    public let tracks: [URL]
    public let trackFrames: [Int]
    public let sampleRateHz: Int

    public var totalFrames: Int { trackFrames.reduce(0, +) }
    public var durationSeconds: Double { Double(totalFrames) / Double(sampleRateHz) }

    static let frequencyHz = 997.0
    static let amplitude = 0.5

    /// The album's signal `seconds` in, from -1 to 1.
    public func value(atSeconds seconds: Double, channel: Int) -> Double {
        Self.amplitude * sin(2 * .pi * Self.frequencyHz * seconds + Double(channel) * .pi / 2)
    }
}

/// Makes the album the first time it's asked for at this rate, depth and first track's length,
/// by default a second and a bit so the join isn't on a convenient frame, and returns it.
public func sineAlbum(
    sampleRateHz: Int, bitsPerSample: Int, firstTrackFrames: Int? = nil, in directory: URL
) throws -> SineAlbum {
    let frames = [firstTrackFrames ?? sampleRateHz + 123, sampleRateHz / 2]
    let album = SineAlbum(tracks: [], trackFrames: frames, sampleRateHz: sampleRateHz)
    let scale = Double(1 << (bitsPerSample - 1))
    var tracks: [URL] = []
    var start = 0
    for (index, count) in frames.enumerated() {
        let url = directory.appendingPathComponent(
            "sine-\(sampleRateHz)-\(bitsPerSample)-\(frames[0])-\(index + 1).flac")
        let first = start
        try makeEncoded(
            at: url, sampleRateHz: sampleRateHz, bitsPerSample: bitsPerSample, frames: count
        ) { frame, channel in
            let seconds = Double(first + frame) / Double(sampleRateHz)
            return Int32((album.value(atSeconds: seconds, channel: channel) * scale).rounded())
        }
        tracks.append(url)
        start += count
    }
    return SineAlbum(tracks: tracks, trackFrames: frames, sampleRateHz: sampleRateHz)
}

/// Half a second of 24-bit 44.1 kHz FLAC holding a different steady level on each channel,
/// `levelOf(channel)`, so a channel mix shows as plain arithmetic on the levels.
func levelTrack(channels: Int, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("levels-44100-24-\(channels)ch.flac")
    try makeEncoded(
        at: url, sampleRateHz: 44_100, bitsPerSample: 24, channels: channels, frames: 22_050
    ) { _, channel in Int32((levelOf(channel) * Double(1 << 23)).rounded()) }
    return url
}

/// Like `levelTrack`, with `levels` on the channels in the WAV and FLAC default order, encoded
/// with afconvert's `arguments`, which name the layout the levels are in and the one the file
/// stores, as `-l MPEG_5_1_A -l MPEG_5_1_D` does for ALAC's C L R Ls Rs LFE. `name` makes the
/// file's name.
func levelTrack(
    named name: String, levels: [Double], afconvert arguments: [String], in directory: URL
) throws -> URL {
    let url = directory.appendingPathComponent("levels-\(name)")
    try makeEncoded(
        at: url, sampleRateHz: 44_100, bitsPerSample: 24, channels: levels.count, frames: 22_050,
        afconvert: arguments
    ) { _, channel in Int32((levels[channel] * Double(1 << 23)).rounded()) }
    return url
}

/// The level `levelTrack` holds on `channel`: 0.1 on the first, 0.2 on the second, and so on.
func levelOf(_ channel: Int) -> Double { 0.1 * Double(channel + 1) }

/// Two minutes of 24-bit 192 kHz FLAC: a sine with noise in the low bits, so it costs about as
/// much to decode as a real hi-res recording. Made the first time it's asked for.
public func hiResTrack(in directory: URL) throws -> URL {
    try sineNoiseTrack(
        sampleRateHz: 192_000, bitsPerSample: 24, channels: 2, seconds: 120, in: directory)
}

/// A sine with noise in the low half of the bits, so it costs about as much to decode as a real
/// recording. Made the first time it's asked for.
public func sineNoiseTrack(
    sampleRateHz rate: Int, bitsPerSample bits: Int, channels: Int, seconds: Int,
    in directory: URL
) throws -> URL {
    let url = directory.appendingPathComponent(
        "sine-noise-\(rate)-\(bits)-\(channels)ch-\(seconds)s.flac")
    var noise = SplitMix64(seed: UInt64(rate / 1000))
    let noiseBits = bits / 2
    try makeEncoded(
        at: url, sampleRateHz: rate, bitsPerSample: bits, channels: channels,
        frames: rate * seconds
    ) { frame, channel in
        let sine = 0.1 * sin(2 * .pi * 997 * Double(frame) / Double(rate) + Double(channel))
        return Int32(sine * Double(1 << (bits - 1)))
            + Int32(truncatingIfNeeded: noise.next() >> UInt64(64 - noiseBits))
            - Int32(1 << (noiseBits - 1))
    }
    return url
}

/// Writes PCM from `sample` as WAV, then encodes it with afconvert's `arguments`, FLAC unless
/// given others, unless `url` already exists. Works in a scratch directory and renames the result
/// into place, so a test running at the same time never sees half a file.
private func makeEncoded(
    at url: URL, sampleRateHz: Int, bitsPerSample: Int, channels: Int = 2, frames: Int,
    afconvert arguments: [String] = ["-f", "flac", "-d", "flac"],
    sample: (_ frame: Int, _ channel: Int) -> Int32
) throws {
    let manager = FileManager.default
    if manager.fileExists(atPath: url.path) { return }
    try manager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let scratch = manager.temporaryDirectory.appendingPathComponent(
        "playback-fixture-\(UUID().uuidString)")
    try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
    let made = Result {
        let wav = scratch.appendingPathComponent("source.wav")
        let encoded = scratch.appendingPathComponent("encoded.\(url.pathExtension)")
        try writeWAV(
            at: wav, sampleRateHz: sampleRateHz, bitsPerSample: bitsPerSample, channels: channels,
            frames: frames,
            sample: sample)
        try runAfconvert(arguments + [wav.path, encoded.path])
        guard rename(encoded.path, url.path) == 0 else {
            throw FixtureError.unexpectedSeed(
                "couldn't move \(encoded.path) into place: errno \(errno)")
        }
    }
    try manager.removeItem(at: scratch)
    try made.get()
}

func writeWAV(
    at url: URL, sampleRateHz: Int, bitsPerSample: Int, channels: Int = 2, frames: Int,
    sample: (Int, Int) -> Int32
) throws {
    let bytesPerSample = bitsPerSample / 8
    let dataBytes = frames * channels * bytesPerSample
    var header = Data("RIFF".utf8)
    header.appendLittleEndian(UInt32(36 + dataBytes))
    header.append(contentsOf: Array("WAVEfmt ".utf8))
    header.appendLittleEndian(UInt32(16))
    header.appendLittleEndian(UInt16(1))  // integer PCM
    header.appendLittleEndian(UInt16(channels))
    header.appendLittleEndian(UInt32(sampleRateHz))
    header.appendLittleEndian(UInt32(sampleRateHz * channels * bytesPerSample))
    header.appendLittleEndian(UInt16(channels * bytesPerSample))
    header.appendLittleEndian(UInt16(bitsPerSample))
    header.append(contentsOf: Array("data".utf8))
    header.appendLittleEndian(UInt32(dataBytes))

    FileManager.default.createFile(atPath: url.path, contents: header)
    let file = try FileHandle(forWritingTo: url)
    try file.seekToEnd()
    // A second of audio at a time, so two minutes at 192 kHz never sits in memory at once.
    var block = Data(capacity: sampleRateHz * channels * bytesPerSample)
    for frame in 0..<frames {
        for channel in 0..<channels {
            withUnsafeBytes(of: sample(frame, channel).littleEndian) {
                block.append(contentsOf: $0.prefix(bytesPerSample))
            }
        }
        if (frame + 1) % sampleRateHz == 0 || frame + 1 == frames {
            try file.write(contentsOf: block)
            block.removeAll(keepingCapacity: true)
        }
    }
    try file.close()
}
