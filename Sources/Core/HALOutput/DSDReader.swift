import CoreAudio
import Foundation
import Metadata
import Playback

/// DSD's silence: alternating bits that average to zero, oldest bit highest.
let dsdIdleByte: UInt8 = 0x69
/// DoP v1.1's markers, frame by frame in turn, in the top byte of each 24-bit word.
let dopMarkers: [UInt8] = [0x05, 0xFA]

/// Where a DoP word goes in the device's samples: little-endian integer PCM, 24-bit packed or
/// 24 bits aligned high in 32 with zero below.
struct DoPLayout: Equatable {
    let sampleBytes: Int
    let channels: Int

    /// Nil for a format that can't carry DoP unchanged: float, big-endian, non-interleaved, fewer
    /// than 24 bits, or another channel count.
    init?(_ format: AudioStreamBasicDescription, channels: Int) {
        let flags = format.mFormatFlags
        guard format.mFormatID == kAudioFormatLinearPCM, flags & kAudioFormatFlagIsFloat == 0,
            flags & kAudioFormatFlagIsBigEndian == 0,
            flags & kAudioFormatFlagIsNonInterleaved == 0, channels > 0,
            format.mChannelsPerFrame == UInt32(channels)
        else { return nil }
        switch (Int(format.mBytesPerFrame) / channels, format.mBitsPerChannel) {
        case (3, 24): sampleBytes = 3
        case (4, 32): sampleBytes = 4
        case (4, 24) where flags & kAudioFormatFlagIsAlignedHigh != 0: sampleBytes = 4
        default: return nil
        }
        self.channels = channels
    }

    var bytesPerFrame: Int { sampleBytes * channels }

    /// Writes `frames` frames of DoP silence, the idle pattern under markers from 0x05.
    func writeSilence(into buffer: UnsafeMutableRawPointer, frames: Int) {
        let output = buffer.assumingMemoryBound(to: UInt8.self)
        var offset = 0
        for frame in 0..<frames {
            for _ in 0..<channels {
                if sampleBytes == 4 {
                    output[offset] = 0
                    offset += 1
                }
                output[offset] = dsdIdleByte
                output[offset + 1] = dsdIdleByte
                output[offset + 2] = dopMarkers[frame & 1]
                offset += 3
            }
        }
    }
}

/// Reads a DSF or DSDIFF file as DoP frames in the device's format (ADR 0064): 16 DSD bits per
/// channel a frame, oldest bit highest, under a marker that alternates with the frame's place in
/// the track. Frames come in pairs, so a track always starts on an even frame of the ring buffer
/// and the markers run on unbroken from one track to the next; the length is rounded up to a
/// pair with DoP silence. Use from one thread.
package final class DSDReader: TrackDecoder {
    package let stream: DSDStream
    /// DoP frames, a whole number of pairs.
    package let lengthFrames: Int64
    private(set) var nextFrame: Int64 = 0
    private let source: FileSource
    private let path: String
    private var layout: DoPLayout?
    private var scratch: [UInt8] = []

    package init(url: URL) throws {
        path = url.path
        do throws(ParseFailure) {
            source = try FileSource(path: url.path, hints: .none)
            stream = try dsdStream(ByteReader(source))
        } catch {
            throw error.error(path: url.path)
        }
        let frames = (stream.bytesPerChannel + 1) / 2
        lengthFrames = Int64(frames + frames % 2)
    }

    /// The PCM rate DoP runs at: the DSD rate over the 16 bits a frame carries.
    package var carrierRateHz: Double { Double(stream.rateHz) / Double(dopDSDBitsPerFrame) }

    package func setOutputFormat(_ format: AudioStreamBasicDescription) throws {
        guard let layout = DoPLayout(format, channels: stream.channels) else {
            throw DeviceOutputError.noDoPLayout(SignalFormat(format))
        }
        self.layout = layout
    }

    /// Rounds down to a pair of frames.
    func seek(toFrame frame: Int64) throws {
        nextFrame = min(max(0, frame), lengthFrames) & ~1
    }

    /// `frames` must be even.
    package func read(into buffer: UnsafeMutableRawPointer, frames: UInt32) throws -> UInt32 {
        guard let layout else { preconditionFailure("setOutputFormat must be called before read") }
        precondition(frames % 2 == 0, "DoP frames are read in pairs")
        let count = Int(min(Int64(frames), lengthFrames - nextFrame))
        guard count > 0 else { return 0 }
        let channels = stream.channels
        let first = Int(nextFrame) * 2
        let end = min(first + count * 2, stream.bytesPerChannel)
        // The run of the file that holds bytes `first..<end` of every channel: whole groups of
        // blocks for DSF.
        let readStart: Int
        let readEnd: Int
        switch stream.interleave {
        case .bytes:
            readStart = first * channels
            readEnd = max(end, first) * channels
        case .blocks(let block):
            readStart = first / block * block * channels
            readEnd = max(end - 1, first) / block * block * channels + block * channels
        }
        let fileStart = stream.dataStart + readStart
        let fileEnd = min(stream.dataStart + readEnd, source.size)
        if scratch.count < fileEnd - fileStart {
            scratch = [UInt8](repeating: 0, count: fileEnd - fileStart)
        }
        if first < end {
            let failure = scratch.withUnsafeMutableBytes { raw -> ParseFailure? in
                do throws(ParseFailure) {
                    try source.read(fileStart..<fileEnd, into: raw)
                    return nil
                } catch {
                    return error
                }
            }
            if let failure { throw failure.error(path: path) }
        }
        // Byte `k` of channel `c` is at `index + c * channelStride` in `scratch`. `index` moves
        // `byteStride` a byte from byte `first`, and at the end of each DSF block jumps past the
        // other channels' blocks, so nothing is divided per byte.
        let byteStride: Int
        let channelStride: Int
        let blockJump: Int
        let blockLength: Int
        var index: Int
        var blockLeft: Int
        let lastIndex: Int
        switch stream.interleave {
        case .bytes:
            byteStride = channels
            channelStride = 1
            blockJump = 0
            blockLength = Int.max
            index = 0
            blockLeft = Int.max
            lastIndex = (end - 1) * channels + channels - 1 - readStart
        case .blocks(let block):
            byteStride = 1
            channelStride = block
            blockJump = block * (channels - 1)
            blockLength = block
            index = first % block
            blockLeft = block - first % block
            lastIndex =
                ((end - 1) / block * channels + channels - 1) * block + (end - 1) % block
                - readStart
        }
        // Frames whose two bytes are both before the end; the rest are idle-padded.
        let full = max(0, min(count, (end - first) / 2))
        precondition(first >= end || lastIndex < scratch.count)
        let markers = (dopMarkers[Int(nextFrame) & 1], dopMarkers[Int(nextFrame + 1) & 1])
        let zeroByte = layout.sampleBytes == 4
        let output = buffer.assumingMemoryBound(to: UInt8.self)
        var offset = 0
        func write(_ newer: UInt8, _ older: UInt8, _ marker: UInt8) {
            if zeroByte {
                output[offset] = 0
                offset += 1
            }
            output[offset] = newer
            output[offset + 1] = older
            output[offset + 2] = marker
            offset += 3
        }
        func advance() {
            index += byteStride
            blockLeft -= 1
            if blockLeft == 0 {
                index += blockJump
                blockLeft = blockLength
            }
        }
        (stream.lsbFirst ? bitReversal : identity).withUnsafeBufferPointer { order in
            scratch.withUnsafeBufferPointer { bytes in
                for frame in 0..<full {
                    let marker = frame & 1 == 0 ? markers.0 : markers.1
                    let older = index
                    advance()
                    let newer = index
                    advance()
                    for channel in 0..<channels {
                        let shift = channel * channelStride
                        write(
                            order[Int(bytes[newer + shift])], order[Int(bytes[older + shift])],
                            marker)
                    }
                }
                for frame in full..<count {
                    let marker = frame & 1 == 0 ? markers.0 : markers.1
                    let k = first + 2 * frame
                    let older = index
                    advance()
                    for channel in 0..<channels {
                        let byte =
                            k < end
                            ? order[Int(bytes[older + channel * channelStride])] : dsdIdleByte
                        write(dsdIdleByte, byte, marker)
                    }
                    advance()
                }
            }
        }
        nextFrame += Int64(count)
        return UInt32(count)
    }
}

/// Each byte as it is, for files whose bytes are already oldest bit highest.
private let identity: [UInt8] = (0...255).map { UInt8($0) }

/// Each byte with its bits in the opposite order, for DSF's oldest-bit-lowest bytes.
private let bitReversal: [UInt8] = (0...255).map { value in
    (0..<8).reduce(UInt8(0)) { $0 | ((UInt8(value) >> $1) & 1) << (7 - $1) }
}
