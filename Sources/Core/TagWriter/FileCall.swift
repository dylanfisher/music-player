import Metadata

/// One file system call the writer makes on a music file, its temp file or its folder. On a
/// NAS each is a round trip, and the bytes a read or write moves cross the network, so the
/// bench prices them as a NAS would and the tests count them (`WriteFaults.fileCall`).
package enum FileCall: Equatable, Sendable {
    /// `stat`, `access`, `ftruncate` or an attribute call.
    case metadata
    case open
    case close
    case read(bytes: Int)
    case write(bytes: Int)
    /// `fsync`, to the drive's cache.
    case flush
    /// `F_FULLFSYNC`, through the drive's cache, or `fsync` where the volume can't.
    case flushDrive
    /// A listing of a music file's folder.
    case list
    /// A clone of the whole file, which a volume that can't clone (SMB) has to copy instead.
    case clone(bytes: Int)
    case rename
    case remove
}

extension WriteFaults {
    func called(_ call: FileCall) { fileCall?(call) }
}

/// A music file read through `FileSource`, each read told to `faults`, so the parsers' reads
/// are counted with the writer's own.
struct MeteredSource: ByteSource {
    let file: FileSource
    let faults: WriteFaults

    init(path: String, faults: WriteFaults) throws(ParseFailure) {
        self.faults = faults
        faults.called(.open)
        // The descriptor closes when the source goes; on a NAS that's a round trip too.
        faults.called(.close)
        file = try FileSource(path: path)
    }

    var size: Int { file.size }

    func read(_ range: Range<Int>) throws(ParseFailure) -> [UInt8] {
        faults.called(.read(bytes: range.count))
        return try file.read(range)
    }
}
