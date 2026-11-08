import Darwin
import Foundation

/// Writes `bytes` over the file at `url` as one only its owner can read or write (mode 0600),
/// whatever it held before, since the config file can hold the Discogs token (ADR 0137). A new
/// file beside it is written and synced, then renamed over it, so a reader finds the old file
/// or the new one, never part of one. The new file's name is the one Foundation's atomic write
/// gives, so `removeLeftoverAtomicWrites(beside:)` removes one a killed process left.
/// `writing` writes the bytes to the open file; tests make it fail partway.
func writeConfigFile(
    _ bytes: [UInt8], to url: URL,
    writing: (Int32, [UInt8]) throws -> Void = writeAll
) throws {
    let temp = url.path + leftoverInfix + UUID().uuidString
    let descriptor = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw posixError() }
    do {
        do {
            // `open`'s mode passes through the umask; `fchmod`'s doesn't.
            guard fchmod(descriptor, 0o600) == 0 else { throw posixError() }
            try writing(descriptor, bytes)
            guard fsync(descriptor) == 0 else { throw posixError() }
        } catch {
            close(descriptor)
            throw error
        }
        guard close(descriptor) == 0 else { throw posixError() }
        guard rename(temp, url.path) == 0 else { throw posixError() }
    } catch {
        unlink(temp)
        throw error
    }
}

/// Writes all of `bytes` to `descriptor`, through short writes.
func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) throws {
    var written = 0
    while written < bytes.count {
        let count = bytes[written...].withUnsafeBytes {
            write(descriptor, $0.baseAddress, $0.count)
        }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw posixError() }
        written += count
    }
}

/// Whether a group or other permission bit is set on the file at `url`, after symbolic links.
/// A file that can't be checked counts as readable, so a secret in it isn't used.
func othersCanRead(_ url: URL) -> Bool {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return true }
    return info.st_mode & 0o077 != 0
}

private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
