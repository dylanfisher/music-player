import AudioToolbox
import Foundation
import Testing

@testable import HALOutput

/// A decoder of stereo float frames from memory, which can fail once it has handed over
/// `failsAfter` frames.
private final class MemoryDecoder: TrackDecoder {
    let frames: [Float]
    var failsAfter: Int64?
    private(set) var nextFrame: Int64 = 0
    var lengthFrames: Int64 { Int64(frames.count / 2) }

    struct Failed: Error {}

    init(_ frames: [Float], failsAfter: Int64? = nil) {
        self.frames = frames
        self.failsAfter = failsAfter
    }

    func setOutputFormat(_ format: AudioStreamBasicDescription) throws {}
    func seek(toFrame frame: Int64) throws { nextFrame = frame }

    func read(into buffer: UnsafeMutableRawPointer, frames count: UInt32) throws -> UInt32 {
        if let failsAfter, nextFrame >= failsAfter { throw Failed() }
        let end = min(lengthFrames, nextFrame + Int64(count), failsAfter ?? .max)
        let read = Int(end - nextFrame)
        frames.withUnsafeBufferPointer {
            buffer.copyMemory(
                from: $0.baseAddress! + Int(nextFrame) * 2, byteCount: read * 2 * 4)
        }
        nextFrame = end
        return UInt32(read)
    }
}

private func sine(_ frames: Int, rate: Double) -> [Float] {
    (0..<frames).flatMap { frame -> [Float] in
        let value = Float(0.5 * sin(2 * .pi * 997 * Double(frame) / rate))
        return [value, value]
    }
}

private let float48k = AudioStreamBasicDescription(
    mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
    mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32,
    mReserved: 0)

/// Everything `converter` gives for `decoder`, then for a flush when `flushing`.
private func drain(
    _ converter: OutputConverter, _ decoder: MemoryDecoder, flushing: Bool = true,
    format: AudioStreamBasicDescription = float48k
) throws -> Data {
    var output = Data()
    let frames: UInt32 = 4096
    var buffer = Data(count: Int(frames * format.mBytesPerFrame))
    func take(_ body: (UnsafeMutableRawPointer) throws -> UInt32) rethrows -> Bool {
        let count = try buffer.withUnsafeMutableBytes { try body($0.baseAddress!) }
        output.append(buffer.prefix(Int(count * format.mBytesPerFrame)))
        return count > 0
    }
    while try take({ try converter.convert(from: decoder, into: $0, frames: frames) }) {}
    if flushing { while try take({ try converter.flush(into: $0, frames: frames) }) {} }
    return output
}

@Test func aFlushGivesUpTheTailAndTheOutputLengthIsTheInputsAtTheNewRate() throws {
    let converter = try OutputConverter(
        from: 44_100, channels: 2, to: float48k, dither: false)
    let decoder = MemoryDecoder(sine(44_223, rate: 44_100))
    let unflushed = try drain(converter, decoder, flushing: false).count / 8
    #expect(converter.nextTrackStartFrame == converter.outputFrame(atInput: 44_223))
    // About a millisecond stays inside until the flush.
    #expect(unflushed < 48_134 && unflushed > 48_134 - 100)
    var tail = Data(count: 4096 * 8)
    var flushed = 0
    while true {
        let count = try tail.withUnsafeMutableBytes {
            try converter.flush(into: $0.baseAddress!, frames: 4096)
        }
        if count == 0 { break }
        flushed += Int(count)
    }
    #expect(converter.isFlushing)
    #expect(converter.nextTrackStartFrame == nil)
    #expect(abs(unflushed + flushed - 48_134) <= 1)
}

@Test func aResetStartsTheSignalAgainAsAFreshConverterWould() throws {
    let input = sine(10_000, rate: 44_100)
    let fresh = try drain(
        try OutputConverter(from: 44_100, channels: 2, to: float48k, dither: false),
        MemoryDecoder(input))
    let reused = try OutputConverter(from: 44_100, channels: 2, to: float48k, dither: false)
    _ = try drain(reused, MemoryDecoder(sine(5_000, rate: 22_050)), flushing: false)
    try reused.reset()
    #expect(reused.nextTrackStartFrame == nil)
    #expect(try drain(reused, MemoryDecoder(input)) == fresh)
}

@Test func aFailedReadThrowsTheDecodersErrorAndTheNextTrackCarriesOn() throws {
    let converter = try OutputConverter(
        from: 44_100, channels: 2, to: float48k, dither: false)
    let failing = MemoryDecoder(sine(20_000, rate: 44_100), failsAfter: 10_000)
    #expect(throws: MemoryDecoder.Failed.self) {
        _ = try drain(converter, failing, flushing: false)
    }
    // What was read before the failure still counts, so the next track lands after it.
    #expect(converter.nextTrackStartFrame == converter.outputFrame(atInput: 10_000))
    let next = try drain(converter, MemoryDecoder(sine(4_410, rate: 44_100)))
    #expect(next.count > 0)
}

@Test func narrowingToSixteenBitsIsDitheredOnlyWhenAsked() throws {
    var int16 = float48k
    int16.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
    int16.mBitsPerChannel = 16
    int16.mBytesPerFrame = 4
    int16.mBytesPerPacket = 4
    // A steady level between two 16-bit steps: rounding gives one value, dither several.
    let level = Float(1000.4) / 32_768
    let input = [Float](repeating: level, count: 2 * 9_600)
    func values(dither: Bool) throws -> Set<Int16> {
        let converter = try OutputConverter(
            from: 48_000, channels: 2, to: int16, dither: dither)
        let data = try drain(converter, MemoryDecoder(input), format: int16)
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        // The middle, away from where the steady level starts and stops.
        return Set(samples[2_000..<(samples.count - 2_000)])
    }
    #expect(try values(dither: false) == [1000])
    #expect(try values(dither: true).count > 1)
}
