import Accelerate
import AudioToolbox
import Foundation
import HALOutput
import Library
import Metadata
import Playback

/// What one pass over a file found: its measures and its spectrogram.
public struct AnalysisResult: Equatable, Sendable {
    public var measures: FileMeasures
    public var spectrogram: Spectrogram
}

enum AnalysisError: Error, Equatable, CustomStringConvertible {
    /// DSD isn't analyzed in phase 45a.
    case dsd
    /// A float sample is NaN or infinite: the file is damaged.
    case nonFiniteSample

    var description: String {
        switch self {
        case .dsd: "DSD files aren't analyzed yet"
        case .nonFiniteSample: "the file holds a sample that isn't a number or is infinite"
        }
    }
}

/// The codecs whose samples are the file's own, so their bits and cutoffs say what the file
/// was made from.
let losslessFormatIDs = Set(
    [kAudioFormatLinearPCM, kAudioFormatFLAC, kAudioFormatAppleLossless].map(fourCharCode))

/// Decodes the file at `url` and measures it in one pass: integer FLAC, ALAC and PCM in their
/// own integer samples, so effective bits are exact, and anything else as float. Reads from
/// the calling thread, so call it off the main one; `latency` makes every read wait as on a
/// network volume. Throws `CancellationError` at the next FFT frame once the task is
/// cancelled, `AnalysisError.dsd` for a DSD file, and `AnalysisError.nonFiniteSample` for a
/// float sample that's NaN or infinite. `progress` hears the share read, from 0
/// to 1, at most every hundredth.
public func analyzeFile(
    at url: URL, latency: FileLatency? = nil, progress: (Double) -> Void = { _ in }
) throws -> AnalysisResult {
    guard !dsdFileExtensions.contains(url.pathExtension.lowercased()) else {
        throw AnalysisError.dsd
    }
    let decoder = try FileDecoder(url: url, latency: latency)
    let format = SignalFormat(decoder.fileFormat)
    let channels = Int(format.channels)
    let integer = readsIntegers(format)
    let storedBits = format.bitsPerChannel.map(Int.init)
    try decoder.setOutputFormat(
        clientFormat(rateHz: format.sampleRateHz, channels: channels, integer: integer))

    let points = SpectrumAccumulator.points
    let hop = SpectrumAccumulator.hopFrames
    let spectrum = SpectrumAccumulator(
        channels: channels,
        expectedWindows: SpectrumAccumulator.windowCount(frames: decoder.lengthFrames))
    let samples = SampleMeasures(
        channels: channels, sampleRateHz: format.sampleRateHz,
        storedBits: integer ? storedBits : nil)
    let decoded = UnsafeMutableRawPointer.allocate(
        byteCount: hop * channels * MemoryLayout<Int32>.size, alignment: 16)
    defer { decoded.deallocate() }
    var block = [Float](repeating: 0, count: hop)
    var windows = Array(repeating: [Float](repeating: 0, count: points), count: channels)
    var filled = 0
    var framesRead: Int64 = 0
    var reported = -1
    while true {
        try Task.checkCancellation()
        let frames = try readHop(decoder, into: decoded, frames: hop)
        guard frames > 0 else { break }
        if integer {
            samples.addIntegers(decoded.assumingMemoryBound(to: Int32.self), frames: frames)
        } else {
            try samples.addFloats(decoded.assumingMemoryBound(to: Float.self), frames: frames)
        }
        if filled == points {
            for channel in 0..<channels {
                windows[channel].withUnsafeMutableBufferPointer { window in
                    let base = window.baseAddress!
                    base.update(from: base + hop, count: points - hop)
                }
            }
            filled = points - hop
        }
        for channel in 0..<channels {
            deinterleave(
                decoded, channel: channel, of: channels, frames: frames, integer: integer,
                into: &block)
            block.withUnsafeBufferPointer { block in
                samples.addChannel(
                    UnsafeBufferPointer(rebasing: block[0..<frames]),
                    channel: channel)
                windows[channel].withUnsafeMutableBufferPointer { window in
                    (window.baseAddress! + filled).update(from: block.baseAddress!, count: frames)
                }
            }
        }
        filled += frames
        if filled == points { spectrum.add(windows) }
        framesRead += Int64(frames)
        if decoder.lengthFrames > 0 {
            let share = Int(100 * framesRead / decoder.lengthFrames)
            if share > reported {
                reported = share
                progress(min(1, Double(share) / 100))
            }
        }
    }
    // A file shorter than a window is one window, padded with silence.
    if spectrum.windows == 0 {
        for channel in 0..<channels {
            for frame in filled..<points { windows[channel][frame] = 0 }
        }
        spectrum.add(windows)
    }
    samples.finish()
    let nyquistHz = format.sampleRateHz / 2
    let durationSeconds = Double(framesRead) / format.sampleRateHz
    let cutoff = Cutoff(
        rowDB: spectrum.averageRowDB, rowHz: nyquistHz / Double(Spectrogram.rows))
    let measures = FileMeasures(
        formatID: format.formatID, sampleRateHz: format.sampleRateHz, storedBits: storedBits,
        channels: channels, isFloat: !integer, durationSeconds: durationSeconds,
        cutoffHz: cutoff?.frequencyHz, cutoffSteepnessDBPerKHz: cutoff?.steepnessDBPerKHz,
        effectiveBits: samples.effectiveBits, identicalChannels: samples.identicalChannels,
        peakDBFS: samples.peakDBFS, truePeakDBTP: samples.truePeakDBTP,
        clippedRuns: samples.clippedRuns, dynamicRange: samples.dynamicRange)
    return AnalysisResult(
        measures: measures,
        spectrogram: spectrum.spectrogram(nyquistHz: nyquistHz, durationSeconds: durationSeconds))
}

/// Whether `format`'s samples are read as integers, for exact effective bits: a lossless
/// integer format that states its depth. One that doesn't, as a FLAC or ALAC whose flags name
/// no source depth, is read as float, with no effective bits.
func readsIntegers(_ format: SignalFormat) -> Bool {
    losslessFormatIDs.contains(format.formatID) && !format.isFloat
        && format.bitsPerChannel != nil
}

/// Interleaved 32-bit samples at the file's rate: signed integers, which hold a lossless
/// file's samples at the top of the word, or floats.
private func clientFormat(rateHz: Double, channels: Int, integer: Bool)
    -> AudioStreamBasicDescription
{
    let bytesPerFrame = UInt32(channels * MemoryLayout<Int32>.size)
    return AudioStreamBasicDescription(
        mSampleRate: rateHz, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: (integer ? kAudioFormatFlagIsSignedInteger : kAudioFormatFlagIsFloat)
            | kAudioFormatFlagIsPacked,
        mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
}

/// Reads until `frames` frames are in or the file ends.
private func readHop(_ decoder: FileDecoder, into buffer: UnsafeMutableRawPointer, frames: Int)
    throws -> Int
{
    let bytesPerFrame = Int(decoder.fileFormat.mChannelsPerFrame) * MemoryLayout<Int32>.size
    var read = 0
    while read < frames {
        let got = try decoder.read(
            into: buffer + read * bytesPerFrame, frames: UInt32(frames - read))
        guard got > 0 else { break }
        read += Int(got)
    }
    return read
}

/// One channel of `frames` interleaved frames as float from -1 to 1.
private func deinterleave(
    _ decoded: UnsafeMutableRawPointer, channel: Int, of channels: Int, frames: Int,
    integer: Bool, into block: inout [Float]
) {
    let stride = vDSP_Stride(channels)
    let count = vDSP_Length(frames)
    if integer {
        let source = decoded.assumingMemoryBound(to: Int32.self) + channel
        vDSP_vflt32(source, stride, &block, 1, count)
        var scale = 1 / Float(1 << 31 as Int64)
        vDSP_vsmul(block, 1, &scale, &block, 1, count)
    } else {
        var one: Float = 1
        vDSP_vsmul(
            decoded.assumingMemoryBound(to: Float.self) + channel, stride, &one, &block, 1, count)
    }
}
