import AudioToolbox

/// Converts what a track's decoder hands it, float at the track's rate and channels, to a device
/// format of another rate, channel count or depth, for a device that can't take the track
/// unchanged (ADR 0071). The signal runs on across the tracks fed to it until it's flushed or
/// reset, so a gapless join is resampled as one signal rather than two with a seam. Use from one
/// thread.
final class OutputConverter {
    /// What decoders feed it: 32-bit float, interleaved.
    let inputFormat: AudioStreamBasicDescription
    private let outputFormat: AudioStreamBasicDescription
    private let converter: AudioConverterRef
    private static let inputFrames = 8192
    private let input: UnsafeMutableRawPointer
    /// Gains from each input channel to each output channel, row-major by output, applied here
    /// before AudioConverter sees the samples; nil when the channel counts match.
    private let mix: [Float]?
    private let mixed: UnsafeMutableRawPointer?
    /// Where input comes from; nil asks the converter for what it still holds.
    private var source: (any TrackDecoder)?
    private var readError: (any Error)?
    /// Input frames taken since the last reset.
    private var taken: Int64 = 0
    /// A flush has been asked for since the last reset, so only a reset lets input in again.
    private(set) var isFlushing = false

    /// `dither` adds TPDF dither at the output's depth, for an integer output narrower than the
    /// track's samples. AudioConverter doesn't dither unless asked: it rounds.
    init(
        from rateHz: Double, channels order: ChannelOrder, to output: AudioStreamBasicDescription,
        dither: Bool
    ) throws {
        let channels = UInt32(order.roles.count)
        inputFormat = floatFormat(rateHz: rateHz, channels: channels)
        outputFormat = output
        let outputChannels = output.mChannelsPerFrame
        mix =
            channels == outputChannels
            ? nil : try channelMix(from: order.roles, to: outputChannels)
        var from = floatFormat(rateHz: rateHz, channels: outputChannels)
        var to = output
        var converter: AudioConverterRef?
        try throwIfError("AudioConverterNew", AudioConverterNew(&from, &to, &converter))
        self.converter = converter!
        input = .allocate(byteCount: Self.inputFrames * Int(4 * channels), alignment: 16)
        mixed =
            mix == nil
            ? nil : .allocate(byteCount: Self.inputFrames * Int(4 * outputChannels), alignment: 16)
        // Normal complexity holds back about a millisecond; mastering holds back ten times that
        // and measured no closer to an ideal sine at maximum quality. A converter that doesn't
        // resample refuses both.
        var properties: [(AudioConverterPropertyID, UInt32)] = []
        if rateHz != output.mSampleRate {
            properties += [
                (
                    kAudioConverterSampleRateConverterComplexity,
                    kAudioConverterSampleRateConverterComplexity_Normal
                ),
                (kAudioConverterSampleRateConverterQuality, kAudioConverterQuality_Max),
            ]
        }
        if dither {
            properties += [
                (kAudioConverterPropertyDithering, kDitherAlgorithm_TPDF),
                (kAudioConverterPropertyDitherBitDepth, output.mBitsPerChannel),
            ]
        }
        for (property, value) in properties {
            var value = value
            try throwIfError(
                "AudioConverterSetProperty",
                AudioConverterSetProperty(
                    self.converter, property, UInt32(MemoryLayout.size(ofValue: value)), &value))
        }
    }

    deinit {
        AudioConverterDispose(converter)
        input.deallocate()
        mixed?.deallocate()
    }

    /// The output frame, counted from the last reset, that input frame `frame` lands on: the
    /// first whose time is at or after it. The converter's output starts at its input's time.
    func outputFrame(atInput frame: Int64) -> Int64 {
        Int64((Double(frame) * outputFormat.mSampleRate / inputFormat.mSampleRate).rounded(.up))
    }

    /// Where the next track fed in lands, counted as `outputFrame` counts, or nil when nothing
    /// carries on: no input since the last reset, or a flush asked for.
    var nextTrackStartFrame: Int64? {
        taken > 0 && !isFlushing ? outputFrame(atInput: taken) : nil
    }

    /// Converts up to `frames` frames from `decoder` into `buffer`. Returns how many: 0 once the
    /// decoder has ended and the converter needs the next track's input, or a flush, to give more.
    func convert(
        from decoder: any TrackDecoder, into buffer: UnsafeMutableRawPointer, frames: UInt32
    )
        throws -> UInt32
    {
        precondition(!isFlushing, "a flushed converter needs a reset before more input")
        source = decoder
        defer { source = nil }
        return try fill(buffer, frames: frames)
    }

    /// What the converter still holds once input has ended, up to `frames` frames. Returns 0
    /// once it's all out.
    func flush(into buffer: UnsafeMutableRawPointer, frames: UInt32) throws -> UInt32 {
        isFlushing = true
        return try fill(buffer, frames: frames)
    }

    /// Drops what the converter holds, for a seek or a track that doesn't carry on the signal.
    func reset() throws {
        try throwIfError("AudioConverterReset", AudioConverterReset(converter))
        taken = 0
        isFlushing = false
    }

    private func fill(_ buffer: UnsafeMutableRawPointer, frames: UInt32) throws -> UInt32 {
        var frames = frames
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: outputFormat.mChannelsPerFrame,
                mDataByteSize: frames * outputFormat.mBytesPerFrame, mData: buffer))
        let status = AudioConverterFillComplexBuffer(
            converter, supplyInput, Unmanaged.passUnretained(self).toOpaque(), &frames, &list, nil)
        switch status {
        case noErr, inputEndedStatus: return frames
        case readFailedStatus:
            guard let error = readError else {
                preconditionFailure("a failed read keeps its error")
            }
            readError = nil
            throw error
        default: throw OSStatusError(operation: "AudioConverterFillComplexBuffer", status: status)
        }
    }

    /// Hands the converter the next frames from the source, mixed to the output's channels.
    fileprivate func supply(
        _ packets: UnsafeMutablePointer<UInt32>, _ list: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        // No source while flushing: none and no error is how a converter is told input has
        // ended for good.
        guard let source else {
            packets.pointee = 0
            return noErr
        }
        let read: UInt32
        do {
            read = try source.read(
                into: input, frames: min(packets.pointee, UInt32(Self.inputFrames)))
        } catch {
            readError = error
            packets.pointee = 0
            return readFailedStatus
        }
        packets.pointee = read
        guard read > 0 else { return inputEndedStatus }
        taken += Int64(read)
        let channels = outputFormat.mChannelsPerFrame
        var data = input
        if let mix, let mixed {
            apply(mix, from: input, to: mixed, frames: Int(read))
            data = mixed
        }
        list.pointee.mBuffers = AudioBuffer(
            mNumberChannels: channels, mDataByteSize: read * 4 * channels, mData: data)
        return noErr
    }

    private func apply(
        _ mix: [Float], from input: UnsafeMutableRawPointer, to output: UnsafeMutableRawPointer,
        frames: Int
    ) {
        let inCount = Int(inputFormat.mChannelsPerFrame)
        let outCount = Int(outputFormat.mChannelsPerFrame)
        let source = input.assumingMemoryBound(to: Float.self)
        let target = output.assumingMemoryBound(to: Float.self)
        for frame in 0..<frames {
            for out in 0..<outCount {
                var sum: Float = 0
                for channel in 0..<inCount {
                    sum += mix[out * inCount + channel] * source[frame * inCount + channel]
                }
                target[frame * outCount + out] = sum
            }
        }
    }
}

private func floatFormat(rateHz: Double, channels: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: rateHz, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
        mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
}

/// Whether `channelMix` has a mix from `inputs` channels to `outputs`: to as many or more, or a
/// downmix to stereo or mono.
func hasChannelMix(from inputs: UInt32, to outputs: UInt32) -> Bool {
    outputs >= inputs || outputs <= 2
}

/// The gains from channels of `roles` to `outputs` channels, row-major by output.
///
/// Fewer outputs: an ITU-R BS.775 downmix to stereo in the first two, centre and surrounds at
/// -3 dB into their side and the LFE left out; a mono output takes the stereo mix's average, so
/// (L+R)/2 for a stereo track. A mix of more than left and right is scaled by a fixed headroom
/// of 1/(1+0.707), -4.6 dB, rather than by its sum of gains, which put a 5.1 track's fronts
/// 7.7 dB down; full scale on several channels at once can then pass 1, which an integer output
/// clips. More outputs: each channel to its own, and a mono track to both of the first two.
/// Other downmixes, such as 8 channels to 6, aren't made.
func channelMix(from roles: [ChannelRole], to outputs: UInt32) throws -> [Float] {
    let (inCount, outCount) = (roles.count, Int(outputs))
    guard hasChannelMix(from: UInt32(inCount), to: outputs) else {
        throw DeviceOutputError.noChannelMix(fromChannels: UInt32(inCount), toChannels: outputs)
    }
    var gains = [Float](repeating: 0, count: inCount * outCount)
    if inCount < outCount {
        for channel in 0..<inCount { gains[channel * inCount + channel] = 1 }
        if inCount == 1 { gains[1] = 1 }
        return gains
    }
    let stereo = stereoMix(roles)
    if outCount == 1 {
        for channel in 0..<inCount {
            gains[channel] = (stereo[0][channel] + stereo[1][channel]) / 2
        }
    } else {
        for side in 0..<2 {
            for channel in 0..<inCount { gains[side * inCount + channel] = stereo[side][channel] }
        }
    }
    return gains
}

/// Left and right gains for each channel of `roles`.
private func stereoMix(_ roles: [ChannelRole]) -> [[Float]] {
    let minus3dB = Float(0.5.squareRoot())
    var sides = [[Float]](repeating: [Float](repeating: 0, count: roles.count), count: 2)
    for (channel, role) in roles.enumerated() {
        let (left, right): (Float, Float) =
            switch role {
            case .left: (1, 0)
            case .right: (0, 1)
            case .centre: (minus3dB, minus3dB)
            case .lfe: (0, 0)
            case .leftSurround: (minus3dB, 0)
            case .rightSurround: (0, minus3dB)
            case .backCentre: (minus3dB / 2, minus3dB / 2)
            }
        sides[0][channel] = left
        sides[1][channel] = right
    }
    let mixesMore = zip(roles, zip(sides[0], sides[1])).contains { role, gains in
        role != .left && role != .right && gains != (0, 0)
    }
    let headroom = mixesMore ? 1 / (1 + minus3dB) : 1
    return sides.map { side in side.map { $0 * headroom } }
}

/// Returned with no frames when the decoder has ended, so the converter hands back what it has
/// made and keeps the rest of the signal for the next track's input. Any status but `noErr`
/// does that; these two are this file's own.
private let inputEndedStatus: OSStatus = 0x656E_6421  // 'end!'
private let readFailedStatus: OSStatus = 0x7265_6421  // 'red!'

private func supplyInput(
    _ converter: AudioConverterRef, _ packets: UnsafeMutablePointer<UInt32>,
    _ list: UnsafeMutablePointer<AudioBufferList>,
    _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    Unmanaged<OutputConverter>.fromOpaque(context!).takeUnretainedValue().supply(packets, list)
}
