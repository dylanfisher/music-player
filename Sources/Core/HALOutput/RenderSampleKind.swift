import CoreAudio
import HALRender

/// The sample layout `HALRenderIOProc` scales for the digital gain, or nil for a layout it can't:
/// big-endian, non-interleaved, or another width.
func renderSampleKind(_ format: AudioStreamBasicDescription) -> HALRenderSampleKind? {
    let flags = format.mFormatFlags
    guard format.mFormatID == kAudioFormatLinearPCM, flags & kAudioFormatFlagIsBigEndian == 0,
        flags & kAudioFormatFlagIsNonInterleaved == 0, format.mChannelsPerFrame > 0
    else { return nil }
    let width = format.mBytesPerFrame / format.mChannelsPerFrame
    if flags & kAudioFormatFlagIsFloat != 0 {
        return width == 4 && format.mBitsPerChannel == 32 ? HALRenderSamplesFloat32 : nil
    }
    let alignedHigh = flags & kAudioFormatFlagIsAlignedHigh != 0
    switch (width, format.mBitsPerChannel) {
    case (2, 16): return HALRenderSamplesInt16
    case (3, 24): return HALRenderSamplesInt24
    case (4, 32): return HALRenderSamplesInt32
    case (4, 24) where alignedHigh: return HALRenderSamplesInt32
    default: return nil
    }
}
