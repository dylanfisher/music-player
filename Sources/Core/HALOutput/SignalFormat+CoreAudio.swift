import AudioToolbox
import Playback

extension SignalFormat {
    /// A file's stored format or a PCM one. ALAC and FLAC store their source depth in the format
    /// flags, as `mBitsPerChannel` is 0 for any compressed format; other codecs are lossy and
    /// have none.
    package init(_ format: AudioStreamBasicDescription) {
        let bits: UInt32?
        switch format.mFormatID {
        case kAudioFormatLinearPCM: bits = format.mBitsPerChannel
        case kAudioFormatAppleLossless, kAudioFormatFLAC: bits = losslessSourceBits(format)
        default: bits = nil
        }
        self.init(
            formatID: fourCharCode(format.mFormatID), sampleRateHz: format.mSampleRate,
            bitsPerChannel: bits, channels: format.mChannelsPerFrame,
            isFloat: format.mFormatID == kAudioFormatLinearPCM
                && format.mFormatFlags & kAudioFormatFlagIsFloat != 0)
    }
}

private func losslessSourceBits(_ format: AudioStreamBasicDescription) -> UInt32? {
    switch format.mFormatFlags {
    case kAppleLosslessFormatFlag_16BitSourceData: 16
    case kAppleLosslessFormatFlag_20BitSourceData: 20
    case kAppleLosslessFormatFlag_24BitSourceData: 24
    case kAppleLosslessFormatFlag_32BitSourceData: 32
    default: nil
    }
}
