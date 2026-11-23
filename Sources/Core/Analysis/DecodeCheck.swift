import Foundation
import HALOutput
import Log
import Metadata
import Playback

private let logger = moduleLogger()

/// Why each damaged one of `paths`, a staged album's files, is damaged: AudioToolbox opened it
/// but failed partway through decoding it, while it was still there at the size it had before
/// (ADR 0222). A file that doesn't open, a DSD file, and one gone or resized when the decode
/// failed, as on a share that dropped, aren't damaged: each is logged and left to the checks
/// after. Decodes every file to its end, one at a time, off the calling thread. Throws only
/// when cancelled.
package func damagedAudio(_ paths: [String]) async throws -> [String] {
    var found: [String] = []
    for path in paths {
        if let damage = try await offMain({ try audioDamage(at: path) }) { found.append(damage) }
    }
    return found
}

/// Why the file at `path` is damaged, or nil. Throws only when cancelled.
func audioDamage(at path: String) throws -> String? {
    let name = (path as NSString).lastPathComponent
    guard !dsdFileExtensions.contains((path as NSString).pathExtension.lowercased()) else {
        return nil
    }
    guard let size = fileSize(path) else {
        logger.info("\(name) wasn't decoded to check it: it can't be read")
        return nil
    }
    let decoder: FileDecoder
    do {
        decoder = try FileDecoder(url: URL(fileURLWithPath: path, isDirectory: false))
        let format = SignalFormat(decoder.fileFormat)
        try decoder.setOutputFormat(
            clientFormat(
                rateHz: format.sampleRateHz, channels: Int(format.channels), integer: false))
    } catch {
        logger.info("\(name) wasn't decoded to check it: \(error)")
        return nil
    }
    let hop = SpectrumAccumulator.hopFrames
    let buffer = UnsafeMutableRawPointer.allocate(
        byteCount: hop * Int(decoder.fileFormat.mChannelsPerFrame) * MemoryLayout<Float>.size,
        alignment: 16)
    defer { buffer.deallocate() }
    var decoded: Int64 = 0
    while true {
        try Task.checkCancellation()
        let frames: Int
        do {
            frames = try readHop(decoder, into: buffer, frames: hop)
        } catch {
            guard fileSize(path) == size else {
                logger.info("\(name) changed or went while it was decoded to check it: \(error)")
                return nil
            }
            let percent = decoder.lengthFrames > 0 ? 100 * decoded / decoder.lengthFrames : 0
            return "\(name) is damaged: it stops decoding \(percent)% of the way in (\(error))"
        }
        guard frames > 0 else { return nil }
        decoded += Int64(frames)
    }
}

/// The size of the file at `path`; nil when it's gone or can't be read, which the callers log.
private func fileSize(_ path: String) -> Int? {
    // Why it can't be read doesn't matter here: either way the file isn't called damaged.
    (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
}
