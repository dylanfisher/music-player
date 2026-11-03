import AudioToolbox

/// What `DeviceOutput` decodes a track through: PCM from AudioToolbox, or DoP from a DSD file.
/// Frames are counted at the track's own rate: the file's, or a DSD file's DoP carrier. Use from
/// one thread.
protocol TrackDecoder: AnyObject {
    var lengthFrames: Int64 { get }
    /// The frame the next `read` starts at.
    var nextFrame: Int64 { get }
    /// Sets the format `read` produces, interleaved: the device's, or a converter's input.
    func setOutputFormat(_ format: AudioStreamBasicDescription) throws
    func seek(toFrame frame: Int64) throws
    /// Decodes up to `frames` frames into `buffer`. Returns how many were decoded: 0 at the end.
    func read(into buffer: UnsafeMutableRawPointer, frames: UInt32) throws -> UInt32
}

extension FileDecoder: TrackDecoder {}
