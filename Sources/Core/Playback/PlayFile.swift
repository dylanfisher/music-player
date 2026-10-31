import CoreAudio
import Foundation
import HALOutput
import Log
import RingBuffer

private let logger = moduleLogger()

public enum PlaybackError: Error, CustomStringConvertible {
    case noDevice(named: String, available: [String])
    case channelMismatch(file: UInt32, device: UInt32)
    case outOfMemory

    public var description: String {
        switch self {
        case .noDevice(let name, let available):
            "no output device matches \"\(name)\". Devices: \(available.joined(separator: ", "))"
        case .channelMismatch(let file, let device):
            "the file has \(file) channels but the device takes \(device)"
        case .outOfMemory: "couldn't allocate the playback buffer"
        }
    }
}

/// Plays one file bit-perfect and blocks until it ends. Takes hog mode on the device, matches
/// its rate to the file, and puts the device back as it was afterwards.
///
/// - Parameters:
///   - deviceName: Part of an output device's name, case-insensitive. Nil means the system
///     default output.
///   - log: Receives a line before opening the file, when playback starts, and when it ends.
///   - progress: Receives seconds played and the file's duration, about twice a second.
///   - shouldStop: Polled while playing. Returning true ends playback early, still restoring the
///     device.
public func playFile(
    at url: URL, deviceName: String?, log: (String) -> Void,
    progress: (_ playedSeconds: Double, _ durationSeconds: Double) -> Void,
    shouldStop: () -> Bool
) throws {
    // Logged first, because opening a file on a network volume can block on a privacy prompt.
    log("opening \(url.path)")
    let decoder = try FileDecoder(url: url)
    let target = try outputDevice(named: deviceName)
    let device = try ExclusiveDevice(id: target.id)
    // Restore the device even when playback fails, then report the playback error.
    let result = Result {
        try play(
            decoder, named: url.lastPathComponent, on: device, target, log, progress, shouldStop)
    }
    try device.close()
    try result.get()
}

private func play(
    _ decoder: FileDecoder, named name: String, on device: ExclusiveDevice,
    _ target: AudioDevice, _ log: (String) -> Void, _ progress: (Double, Double) -> Void,
    _ shouldStop: () -> Bool
) throws {
    let file = decoder.fileFormat
    var format = try device.configure(sampleRateHz: file.mSampleRate)
    guard format.mChannelsPerFrame == file.mChannelsPerFrame else {
        throw PlaybackError.channelMismatch(
            file: file.mChannelsPerFrame, device: format.mChannelsPerFrame)
    }
    // The converter rejects the non-mixable flag; it describes the hardware, not the samples.
    format.mFormatFlags &= ~kAudioFormatFlagIsNonMixable
    try decoder.setOutputFormat(format)
    log(
        "\(name): \(kilohertz(file.mSampleRate)) kHz, \(file.mChannelsPerFrame) ch"
            + " → \(target.name): \(try device.physicalFormat().summary), hog mode")

    let bytesPerFrame = Int(format.mBytesPerFrame)
    // Two seconds of audio rides out NAS read stalls.
    guard let ring = RingBufferCreate(Int(format.mSampleRate) * bytesPerFrame * 2) else {
        throw PlaybackError.outOfMemory
    }
    defer { RingBufferDestroy(ring) }

    let chunkFrames = 4096
    let chunk = UnsafeMutableRawPointer.allocate(
        byteCount: chunkFrames * bytesPerFrame, alignment: 16)
    defer { chunk.deallocate() }
    var chunkBytes = 0
    var chunkOffset = 0
    var decoded = 0
    var finished = false

    // Decodes and writes until the ring buffer is full or the file ends.
    func fill() throws {
        while true {
            if chunkOffset == chunkBytes {
                let frames = try decoder.read(into: chunk, frames: UInt32(chunkFrames))
                if frames == 0 {
                    finished = true
                    return
                }
                chunkBytes = Int(frames) * bytesPerFrame
                chunkOffset = 0
                decoded += Int(frames)
            }
            let written = RingBufferWrite(ring, chunk + chunkOffset, chunkBytes - chunkOffset)
            chunkOffset += written
            if written == 0 { return }
        }
    }

    let duration = Double(decoder.lengthFrames) / format.mSampleRate
    var lastReport = Date.distantPast
    // Played = decoded minus what's still queued in the chunk and the ring buffer.
    func report() {
        guard Date().timeIntervalSince(lastReport) >= 0.5 else { return }
        lastReport = Date()
        let queued = (chunkBytes - chunkOffset + RingBufferReadable(ring)) / bytesPerFrame
        progress(Double(decoded - queued) / format.mSampleRate, duration)
    }

    try fill()
    try device.start(reading: ring)
    var underrunBytes: UInt64 = 0
    // The ring buffer must not be freed while the IO proc is running, so stop before rethrowing.
    let result = Result {
        while !finished && !shouldStop() {
            Thread.sleep(forTimeInterval: 0.01)
            try fill()
            report()
        }
        underrunBytes = device.underrunBytes
        while RingBufferReadable(ring) > 0 && !shouldStop() {
            Thread.sleep(forTimeInterval: 0.01)
            report()
        }
        // The last IO buffer is still playing when the ring buffer empties.
        if !shouldStop() { Thread.sleep(forTimeInterval: 0.1) }
    }
    try device.stop()
    try result.get()

    let seconds = Double(decoded) / format.mSampleRate
    let underrunFrames = underrunBytes / UInt64(bytesPerFrame)
    if underrunFrames > 0 {
        logger.error("\(name): \(underrunFrames, privacy: .public) frames of underrun")
    }
    log(
        "\(shouldStop() ? "stopped" : "done"): \(String(format: "%.1f", seconds)) s,"
            + " underruns: \(underrunFrames) frames")
}

private func outputDevice(named name: String?) throws -> AudioDevice {
    let devices = try AudioDevice.outputDevices()
    if let name {
        guard let match = devices.first(where: { $0.name.localizedCaseInsensitiveContains(name) })
        else { throw PlaybackError.noDevice(named: name, available: devices.map(\.name)) }
        return match
    }
    let id = try AudioDevice.defaultOutputID()
    guard let match = devices.first(where: { $0.id == id }) else {
        throw PlaybackError.noDevice(named: "default output", available: devices.map(\.name))
    }
    return match
}
