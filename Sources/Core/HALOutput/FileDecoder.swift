import AudioToolbox
import Foundation

/// Reads any file AudioToolbox can decode (FLAC, ALAC, WAV, AIFF, …) as PCM in a format the
/// caller chooses. Use from one thread.
final class FileDecoder {
    /// The format stored in the file. For compressed formats `mBitsPerChannel` is 0.
    let fileFormat: AudioStreamBasicDescription
    /// Frames at the file's own rate.
    let lengthFrames: Int64
    private let file: ExtAudioFileRef
    private let channels: ChannelReading
    private var bytesPerFrame: UInt32 = 0
    /// The frame the next `read` starts at. The client format keeps the file's rate, so a frame
    /// read is a frame of the file.
    private(set) var nextFrame: Int64 = 0

    init(url: URL) throws {
        var file: ExtAudioFileRef?
        try throwIfError("ExtAudioFileOpenURL", ExtAudioFileOpenURL(url as CFURL, &file))
        self.file = file!

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        try throwIfError(
            "ExtAudioFileGetProperty(FileDataFormat)",
            ExtAudioFileGetProperty(self.file, kExtAudioFileProperty_FileDataFormat, &size, &format)
        )
        fileFormat = format

        var length: Int64 = 0
        size = UInt32(MemoryLayout.size(ofValue: length))
        try throwIfError(
            "ExtAudioFileGetProperty(FileLengthFrames)",
            ExtAudioFileGetProperty(
                self.file, kExtAudioFileProperty_FileLengthFrames, &size, &length)
        )
        lengthFrames = length
        channels = try ChannelReading(self.file, channels: Int(format.mChannelsPerFrame))
    }

    /// The order `read` hands the channels on in.
    var channelOrder: ChannelOrder { channels.order }

    deinit { ExtAudioFileDispose(file) }

    /// Sets the format `read` produces. Must be interleaved PCM with the file's channel count.
    func setOutputFormat(_ format: AudioStreamBasicDescription) throws {
        var format = format
        try throwIfError(
            "ExtAudioFileSetProperty(ClientDataFormat)",
            ExtAudioFileSetProperty(
                file, kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout.size(ofValue: format)), &format))
        try channels.apply(to: file)
        bytesPerFrame = format.mBytesPerFrame
    }

    /// Makes the next `read` start at `frame`, counted at the file's rate.
    func seek(toFrame frame: Int64) throws {
        try throwIfError("ExtAudioFileSeek", ExtAudioFileSeek(file, frame))
        nextFrame = frame
    }

    /// Decodes up to `frames` frames into `buffer`. Returns how many were decoded: 0 at the end.
    func read(into buffer: UnsafeMutableRawPointer, frames: UInt32) throws -> UInt32 {
        precondition(bytesPerFrame > 0, "setOutputFormat must be called before read")
        var frames = frames
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: fileFormat.mChannelsPerFrame,
                mDataByteSize: frames * bytesPerFrame, mData: buffer))
        try throwIfError("ExtAudioFileRead", ExtAudioFileRead(file, &frames, &list))
        nextFrame += Int64(frames)
        return frames
    }
}
