import AudioToolbox

/// Converts what a track's decoder hands it, float at the track's rate and channels, to a device
/// format of another rate or channel count, for a device that can't take the track unchanged
/// (ADR 0071). The signal runs on across the tracks fed to it until it's flushed or reset, so a
/// gapless join is resampled as one signal rather than two with a seam. Use from one thread.
final class RateConverter {
    /// What decoders feed it: 32-bit float, interleaved.
    let inputFormat: AudioStreamBasicDescription
    private let outputFormat: AudioStreamBasicDescription
    private let converter: AudioConverterRef
    private static let inputFrames = 8192
    private let input: UnsafeMutableRawPointer
    /// Where input comes from; nil asks the converter for what it still holds.
    private var source: (any TrackDecoder)?
    private var readError: (any Error)?
    /// Input frames taken since the last reset.
    private var taken: Int64 = 0
    /// A flush has been asked for since the last reset, so only a reset lets input in again.
    private(set) var isFlushing = false

    init(from rateHz: Double, channels: UInt32, to output: AudioStreamBasicDescription) throws {
        let bytesPerFrame = 4 * channels
        inputFormat = AudioStreamBasicDescription(
            mSampleRate: rateHz, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        outputFormat = output
        var from = inputFormat
        var to = output
        var converter: AudioConverterRef?
        try throwIfError("AudioConverterNew", AudioConverterNew(&from, &to, &converter))
        self.converter = converter!
        input = .allocate(byteCount: Self.inputFrames * Int(bytesPerFrame), alignment: 16)
        // Normal complexity holds back about a millisecond; mastering holds back ten times that
        // and measured no closer to an ideal sine at maximum quality.
        for (property, value) in [
            (
                kAudioConverterSampleRateConverterComplexity,
                kAudioConverterSampleRateConverterComplexity_Normal
            ),
            (kAudioConverterSampleRateConverterQuality, kAudioConverterQuality_Max),
        ] {
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
            let error = readError
            readError = nil
            throw error!
        default: throw OSStatusError(operation: "AudioConverterFillComplexBuffer", status: status)
        }
    }

    /// Hands the converter the next frames from the source.
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
        list.pointee.mBuffers = AudioBuffer(
            mNumberChannels: inputFormat.mChannelsPerFrame,
            mDataByteSize: read * inputFormat.mBytesPerFrame, mData: input)
        return noErr
    }
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
    Unmanaged<RateConverter>.fromOpaque(context!).takeUnretainedValue().supply(packets, list)
}
