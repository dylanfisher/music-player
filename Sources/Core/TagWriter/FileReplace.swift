import Darwin
import Foundation
import Log
import Metadata

private let logger = moduleLogger()

/// What says a file is the one that was read: if any of it changes, something else wrote it.
struct FileIdentity: Equatable {
    var device: Int
    var inode: UInt64
    var size: Int
    var modifiedNanoseconds: Int

    init(_ info: stat) {
        device = Int(info.st_dev)
        inode = info.st_ino
        size = Int(info.st_size)
        modifiedNanoseconds =
            Int(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int(info.st_mtimespec.tv_nsec)
    }

    init(path: String) throws(TagWriteError) {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw systemError(path, .unreadable, FileFailure.stat)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw TagWriteError(path: path, kind: .unsupported, detail: FileFailure.notRegular)
        }
        self.init(info)
    }
}

/// Faults the corpus run and the tests inject between writing the temp file and renaming it.
package struct WriteFaults: Sendable {
    /// Runs once the file is read and planned, before the temp file is made from it. A throw
    /// stops the write the way a failure there would.
    var beforeWritingTemp: (@Sendable (_ original: String) throws -> Void)?
    /// Runs once the temp file is written and checked, before the original is checked for
    /// changes and replaced. A throw stops the write the way a failure there would.
    package var beforeReplacing: (@Sendable (_ original: String, _ temp: String) throws -> Void)?
    /// Stops right before the rename and leaves the temp file, as a crash there would.
    package var crashBeforeRename = false

    init() {}
}

/// The temp files a write of `path` may have left beside it, by path:
/// `.<name>.<random>.tagwrite`. Hidden, so the scanner skips one a crash leaves; random, so
/// nobody else who can write the folder can create the name first.
package func leftoverTemps(for path: String) throws -> [String] {
    let folder = (path as NSString).deletingLastPathComponent
    let prefix = "." + (path as NSString).lastPathComponent + "."
    return try FileManager.default.contentsOfDirectory(atPath: folder).filter {
        $0.hasPrefix(prefix) && $0.hasSuffix(tempSuffix)
    }
    .map { folder + "/" + $0 }
}

private let tempSuffix = ".tagwrite"

/// A new temp name for `path`, with 128 random bits.
private func newTempName(for path: String) -> String {
    let random = (0..<2).map { _ in
        let hex = String(UInt64.random(in: .min ... .max), radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
    return "." + (path as NSString).lastPathComponent + "." + random.joined() + tempSuffix
}

/// The temp file a write made, and what it was when the write finished, so the rename can
/// check that its name still holds the same file.
struct TempFile {
    var path: String
    var identity: FileIdentity
}

/// Fails unless the file and its folder can be written and the file isn't locked. A rename
/// would replace a read-only file in a writable folder, so the file's own permission is checked
/// too.
func requireWritable(_ path: String) throws(TagWriteError) {
    var info = stat()
    guard lstat(path, &info) == 0 else { throw systemError(path, .unreadable, FileFailure.stat) }
    let locked = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)
    guard info.st_flags & locked == 0 else {
        throw TagWriteError(path: path, kind: .notWritable, detail: "the file is locked")
    }
    // A rename would leave the other names on the old file, so the edit would split them.
    guard info.st_nlink <= 1 else {
        throw TagWriteError(
            path: path, kind: .unsupported,
            detail: "the file has \(info.st_nlink) hard links, which replacing it would break")
    }
    guard access(path, W_OK) == 0 else {
        throw systemError(path, .notWritable, "the file can't be written")
    }
    let folder = (path as NSString).deletingLastPathComponent
    guard access(folder, W_OK | X_OK) == 0 else {
        throw systemError(path, .notWritable, "its folder can't be written")
    }
}

/// How much one copy step moves when the audio has to move.
private let copyBytes = 4 * 1024 * 1024

/// Writes `segments` to a new temp file beside `original`, which must still be `identity`.
/// When every kept range stays where it was, the temp file starts as an APFS clone of the open
/// original and only the new bytes are written; otherwise, or where the volume can't clone
/// (SMB), it's written whole. Then it takes the original's mode, flags, ACL, extended
/// attributes (Finder tags among them) and creation date; its mtime is new. Temp files an
/// earlier write left are removed first.
func writeTemp(_ segments: [Segment], from original: String, identity: FileIdentity)
    throws(TagWriteError) -> TempFile
{
    let leftovers: [String]
    do {
        leftovers = try leftoverTemps(for: original)
    } catch {
        throw TagWriteError(
            path: original, kind: .writeFailed, detail: "can't list its folder: \(error)")
    }
    for leftover in leftovers where unlink(leftover) != 0 && errno != ENOENT {
        throw systemError(original, .writeFailed, "can't remove the old temp file \(leftover)")
    }
    // Not through a link, and the file that opened must be the one that was read: someone who
    // can write the folder could have swapped another in.
    let source = open(original, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard source >= 0 else { throw systemError(original, .unreadable, FileFailure.open) }
    defer { close(source) }
    var info = stat()
    guard fstat(source, &info) == 0 else {
        throw systemError(original, .unreadable, FileFailure.stat)
    }
    guard FileIdentity(info) == identity, info.st_mode & S_IFMT == S_IFREG else {
        throw TagWriteError(path: original, kind: .changedDuringWrite, detail: replacedDetail)
    }
    let folderPath = (original as NSString).deletingLastPathComponent
    let folder = open(folderPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard folder >= 0 else { throw systemError(original, .writeFailed, "can't open its folder") }
    defer { close(folder) }
    let name = newTempName(for: original)
    let temp = folderPath + "/" + name

    var placed: [(offset: Int, segment: Segment)] = []
    var offset = 0
    for segment in segments {
        placed.append((offset, segment))
        offset += segment.count
    }
    let total = offset
    let inPlace = placed.allSatisfy { item in
        if case .original(let range) = item.segment { return range.lowerBound == item.offset }
        return true
    }

    var cloned = false
    if inPlace {
        if fclonefileat(source, folder, name, 0) == 0 {
            cloned = true
        } else if errno != ENOTSUP && errno != EXDEV {
            throw systemError(original, .writeFailed, "can't clone it to \(temp)")
        }
    }
    let destination = openTemp(name, in: folder, cloned: cloned)
    guard destination >= 0 else {
        let error = systemError(original, .writeFailed, "can't create the temp file \(temp)")
        if cloned { unlinkat(folder, name, 0) }
        throw error
    }
    do throws(TagWriteError) {
        defer { close(destination) }
        try requireOwnTemp(destination, name, in: folder, device: info.st_dev, original)
        if cloned {
            guard ftruncate(destination, off_t(total)) == 0 else {
                throw systemError(original, .writeFailed, "can't size the temp file")
            }
            for (offset, segment) in placed {
                if case .bytes(let bytes) = segment {
                    try writeAll(bytes, to: destination, at: offset, original)
                }
            }
        } else {
            for (offset, segment) in placed {
                switch segment {
                case .bytes(let bytes): try writeAll(bytes, to: destination, at: offset, original)
                case .original(let range):
                    try copy(range, from: source, to: destination, at: offset, original)
                }
            }
        }
        // The attributes go first, so the flush covers them too before the rename.
        try copyAttributes(from: source, info, to: destination, original)
        try flush(destination, original, .writeFailed)
        var written = stat()
        guard fstat(destination, &written) == 0 else {
            throw systemError(original, .writeFailed, "can't stat the temp file")
        }
        return TempFile(path: temp, identity: FileIdentity(written))
    } catch {
        unlinkat(folder, name, 0)
        throw error
    }
}

let replacedDetail = "something else replaced the file while its tags were written"

/// Opens the temp file `name` in `folder` for writing, without following a link. A clone
/// already exists; a whole write creates the file, which refuses any existing name.
func openTemp(_ name: String, in folder: Int32, cloned: Bool) -> Int32 {
    let create = cloned ? 0 : O_CREAT | O_EXCL
    return openat(folder, name, O_WRONLY | create | O_NOFOLLOW | O_CLOEXEC, 0o600)
}

/// Fails unless `descriptor` is the file `name` names in `folder`: a regular file of this user
/// with one link, on the original's volume. Someone who can write the folder could otherwise
/// have swapped a file or a hard link to one in between the clone and the open.
private func requireOwnTemp(
    _ descriptor: Int32, _ name: String, in folder: Int32, device: dev_t, _ original: String
) throws(TagWriteError) {
    var opened = stat()
    var named = stat()
    guard fstat(descriptor, &opened) == 0, fstatat(folder, name, &named, AT_SYMLINK_NOFOLLOW) == 0
    else { throw systemError(original, .writeFailed, "can't stat the temp file") }
    guard opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1,
        opened.st_uid == geteuid(), opened.st_dev == device,
        named.st_dev == opened.st_dev, named.st_ino == opened.st_ino
    else { throw TagWriteError(path: original, kind: .changedDuringWrite, detail: tempSwapDetail) }
}

let tempSwapDetail = "something else replaced the temp file while the tags were written"

/// Fails unless the temp file's name still holds the file the write made, with no other link.
func requireUnchanged(_ temp: TempFile, _ original: String) throws(TagWriteError) {
    var info = stat()
    guard lstat(temp.path, &info) == 0 else {
        throw systemError(original, .writeFailed, "can't stat the temp file")
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
        FileIdentity(info) == temp.identity
    else { throw TagWriteError(path: original, kind: .changedDuringWrite, detail: tempSwapDetail) }
}

private func writeAll(
    _ bytes: [UInt8], to descriptor: Int32, at offset: Int, _ path: String
) throws(TagWriteError) {
    var done = 0
    while done < bytes.count {
        let count = bytes.withUnsafeBytes {
            pwrite(descriptor, $0.baseAddress! + done, bytes.count - done, off_t(offset + done))
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw systemError(path, .writeFailed, "can't write the temp file")
        }
        done += count
    }
}

private func copy(
    _ range: Range<Int>, from source: Int32, to destination: Int32, at offset: Int,
    _ path: String
) throws(TagWriteError) {
    var buffer = [UInt8](repeating: 0, count: min(copyBytes, range.count))
    var done = 0
    while done < range.count {
        let want = min(buffer.count, range.count - done)
        let count = buffer.withUnsafeMutableBytes {
            pread(source, $0.baseAddress, want, off_t(range.lowerBound + done))
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw systemError(path, .unreadable, FileFailure.read)
        }
        guard count > 0 else {
            throw TagWriteError(
                path: path, kind: .changedDuringWrite, detail: "the file got shorter while copying")
        }
        try writeAll(Array(buffer[0..<count]), to: destination, at: offset + done, path)
        done += count
    }
}

/// Everything but the data and the mtime, so the edited file keeps the original's attributes.
private func copyAttributes(
    from source: Int32, _ info: stat, to destination: Int32, _ path: String
) throws(TagWriteError) {
    guard fcopyfile(source, destination, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)) == 0
    else { throw systemError(path, .writeFailed, "can't copy its extended attributes") }
    guard fchmod(destination, info.st_mode & 0o7777) == 0 else {
        throw systemError(path, .writeFailed, "can't copy its permissions")
    }
    var created = info.st_birthtimespec
    var list = attrlist()
    list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    list.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
    guard fsetattrlist(destination, &list, &created, MemoryLayout<timespec>.size, 0) == 0 else {
        throw systemError(path, .writeFailed, "can't copy its creation date")
    }
    guard fchflags(destination, info.st_flags) == 0 else {
        throw systemError(path, .writeFailed, "can't copy its file flags")
    }
}

/// Renames `temp` over `original`, then flushes the folder so the rename survives a crash.
func replace(_ original: String, with temp: String) throws(TagWriteError) {
    guard rename(temp, original) == 0 else {
        let error = systemError(original, .writeFailed, "can't replace it with the temp file")
        unlink(temp)
        throw error
    }
    let folder = open((original as NSString).deletingLastPathComponent, O_RDONLY | O_CLOEXEC)
    // The rename is done either way; a folder that can't be flushed (some network volumes)
    // only loses the guarantee that it survives a power cut, so it's logged, not thrown.
    if folder < 0 || fsync(folder) != 0 {
        logger.notice(
            "couldn't flush the folder of \(original): \(String(cString: strerror(errno)))")
    }
    if folder >= 0 { close(folder) }
}
