import Darwin
import Foundation

/// Writes zeros to `filler` until its volume has no room left, down to the smallest block, as a
/// full disk for the writes after it. Throws on any failure but the volume filling up.
public func fillVolume(with filler: URL) throws {
    let descriptor = open(filler.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    defer { close(descriptor) }
    for size in [1 << 20, 1 << 12, 512] {
        let chunk = [UInt8](repeating: 0, count: size)
        while true {
            let written = write(descriptor, chunk, size)
            if written > 0 { continue }
            guard written < 0, errno == ENOSPC else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            break
        }
    }
}
