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
    /// Set when the file is read through `FileLatency`'s callbacks, which it must outlive.
    private let slowFile: SlowFile?
    private let channels: ChannelReading
    private var bytesPerFrame: UInt32 = 0
    /// The frame the next `read` starts at. The client format keeps the file's rate, so a frame
    /// read is a frame of the file.
    private(set) var nextFrame: Int64 = 0

    /// With `latency`, every read AudioToolbox makes waits as on a network volume.
    init(url: URL, latency: FileLatency? = nil) throws {
        var file: ExtAudioFileRef?
        if let latency {
            let slowFile = try SlowFile(url: url, latency: latency)
            self.slowFile = slowFile
            do {
                try throwIfError(
                    "ExtAudioFileWrapAudioFileID",
                    ExtAudioFileWrapAudioFileID(try slowFile.openAudioFile(), false, &file))
            } catch {
                slowFile.close()
                throw error
            }
        } else {
            slowFile = nil
            try throwIfError("ExtAudioFileOpenURL", ExtAudioFileOpenURL(url as CFURL, &file))
        }
        let opened = file!
        self.file = opened
        // `deinit` doesn't run for an init that throws from here, so close what's open.
        do {
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout.size(ofValue: format))
            try throwIfError(
                "ExtAudioFileGetProperty(FileDataFormat)",
                ExtAudioFileGetProperty(
                    opened, kExtAudioFileProperty_FileDataFormat, &size, &format)
            )
            var length: Int64 = 0
            size = UInt32(MemoryLayout.size(ofValue: length))
            try throwIfError(
                "ExtAudioFileGetProperty(FileLengthFrames)",
                ExtAudioFileGetProperty(
                    opened, kExtAudioFileProperty_FileLengthFrames, &size, &length)
            )
            channels = try ChannelReading(opened, channels: Int(format.mChannelsPerFrame))
            fileFormat = format
            lengthFrames = length
        } catch {
            ExtAudioFileDispose(opened)
            slowFile?.close()
            throw error
        }
    }

    /// The order `read` hands the channels on in.
    var channelOrder: ChannelOrder { channels.order }

    deinit {
        ExtAudioFileDispose(file)
        slowFile?.close()
    }

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

/// What reading a file costs on a network volume, for benchmarks: opening it takes
/// `openSeconds`, and each `blockBytes` of the file the decoder first reads `readSeconds`. An
/// SMB client reads ahead in large requests and keeps what it read while the file is open, so a
/// NAS's cost is per request, not per byte and not per small read AudioToolbox makes.
public struct FileLatency: Sendable {
    public var openSeconds: Double
    public var readSeconds: Double
    /// The largest read macOS's SMB client asks for.
    static let blockBytes: Int64 = 1 << 20
    /// Called on the decoding thread after each block's wait, so a test can act while a refill
    /// is reading.
    var blockRead: @Sendable () -> Void = {}

    public init(openSeconds: Double, readSeconds: Double) {
        self.openSeconds = openSeconds
        self.readSeconds = readSeconds
    }
}

/// A file AudioToolbox reads through callbacks that wait `FileLatency`'s time.
private final class SlowFile {
    private let descriptor: Int32
    private let size: Int64
    private let readSeconds: Double
    private let blockRead: @Sendable () -> Void
    private var audioFile: AudioFileID?
    /// The blocks read so far. AudioToolbox calls back on the thread that reads the file.
    private var fetched: Set<Int64> = []

    init(url: URL, latency: FileLatency) throws {
        Thread.sleep(forTimeInterval: latency.openSeconds)
        descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw POSIXError(.EINVAL)
        }
        size = Int64(status.st_size)
        readSeconds = latency.readSeconds
        blockRead = latency.blockRead
    }

    /// Opens the file for AudioToolbox, which reads it through this object until `close()`.
    func openAudioFile() throws -> AudioFileID {
        let read: AudioFile_ReadProc = { client, position, count, buffer, actual in
            let file = Unmanaged<SlowFile>.fromOpaque(client).takeUnretainedValue()
            file.fetch(position, count: Int64(count))
            let bytes = pread(file.descriptor, buffer, Int(count), position)
            guard bytes >= 0 else {
                actual.pointee = 0
                return OSStatus(kAudioFileUnspecifiedError)
            }
            actual.pointee = UInt32(bytes)
            return noErr
        }
        let size: AudioFile_GetSizeProc = { client in
            Unmanaged<SlowFile>.fromOpaque(client).takeUnretainedValue().size
        }
        var opened: AudioFileID?
        try throwIfError(
            "AudioFileOpenWithCallbacks",
            AudioFileOpenWithCallbacks(
                Unmanaged.passUnretained(self).toOpaque(), read, nil, size, nil, 0, &opened))
        audioFile = opened
        return opened!
    }

    /// Waits for each block of the range not read before.
    private func fetch(_ position: Int64, count: Int64) {
        guard count > 0 else { return }
        let blocks =
            position / FileLatency.blockBytes...(position + count - 1) / FileLatency.blockBytes
        for block in blocks where fetched.insert(block).inserted {
            Thread.sleep(forTimeInterval: readSeconds)
            blockRead()
        }
    }

    func close() {
        if let audioFile { AudioFileClose(audioFile) }
        Darwin.close(descriptor)
    }
}
