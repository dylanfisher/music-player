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

    /// `parsed`, read from the file when it was this.
    func stamp(_ parsed: ParsedFile) -> StampedParse {
        StampedParse(parsed: parsed, sizeBytes: size, modifiedNanoseconds: modifiedNanoseconds)
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

/// Faults the corpus run and the tests inject between planning a write and finishing it.
package struct WriteFaults: Sendable {
    /// Off, a tag that fits the file's padding goes through the temp file too, so the temp
    /// file's faults can be injected on any file.
    package var writesInPlace = true
    /// Runs once the file is read and planned, before the temp file is made from it or the
    /// original is overwritten. A throw stops the write the way a failure there would.
    var beforeWritingTemp: (@Sendable (_ original: String) throws -> Void)?
    /// Runs once the temp file is written and checked, or once a write in place is journaled,
    /// before the original is checked for changes and replaced or overwritten. `temp` is nil
    /// for a write in place. A throw stops the write the way a failure there would.
    package var beforeReplacing: (@Sendable (_ original: String, _ temp: String?) throws -> Void)?
    /// Runs right after the temp file is closed, where an SMB server sets the mtime of a file
    /// written through the handle. A throw stops the write the way a failure there would.
    var whenTempCloses: (@Sendable (_ temp: String) throws -> Void)?
    /// Asked for each extended attribute the temp file is about to take, by name, and for its
    /// ACL as "acl"; an errno makes that copy fail with it, as a volume that refuses the
    /// attribute does.
    var refusingAttribute: (@Sendable (_ name: String) -> Int32?)?
    /// The attributes a refusal leaves off the temp file. Tests add one of their own, as no
    /// process can set or remove `com.apple.provenance`, so a test can't give a file one.
    var unsettable = unsettableAttributes
    /// Stops right before the rename and leaves the temp file, as a crash there would.
    package var crashBeforeRename = false
    /// Writes only this many bytes of each write in place, then stops the batch and leaves the
    /// files and the journal as they are, as a crash mid-write would.
    package var tornWriteBytes: Int?
    /// Stops the batch after this step of its writes in place, as a crash there would.
    var crashAfter: BatchStep?
    /// Runs once a write in place is flushed and closed, before its read-back. A throw fails
    /// the write after the original was overwritten.
    var afterOverwriting: (@Sendable (_ original: String) throws -> Void)?
    /// Told of each file system call on a music file, its temp file or its folder, and of each
    /// read the parsers make there, from whichever thread makes it.
    package var fileCall: (@Sendable (FileCall) -> Void)?

    init() {}
}

/// The temp files a write of `path` may have left beside it, by path:
/// `.<name>.<random>.tagwrite`. Hidden, so the scanner skips one a crash leaves; random, so
/// nobody else who can write the folder can create the name first.
package func leftoverTemps(for path: String) throws -> [String] {
    let folder = (path as NSString).deletingLastPathComponent
    return try FileManager.default.contentsOfDirectory(atPath: folder).filter {
        isTemp($0, of: path)
    }
    .map { folder + "/" + $0 }
}

/// Whether the name `name` in `path`'s folder is one of `path`'s temp files.
private func isTemp(_ name: String, of path: String) -> Bool {
    name.hasPrefix("." + (path as NSString).lastPathComponent + ".") && name.hasSuffix(tempSuffix)
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
func requireWritable(_ path: String, _ faults: WriteFaults) throws(TagWriteError) {
    // The `lstat` and the two `access` calls.
    for _ in 0..<3 { faults.called(.metadata) }
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
/// attributes (Finder tags among them) and creation date; its mtime is new. The caller removes
/// the temp files an earlier write left, a batch at a time (`removeLeftoverTemps`).
func writeTemp(
    _ segments: [Segment], from original: String, identity: FileIdentity,
    faults: WriteFaults = WriteFaults()
) throws(TagWriteError) -> TempFile {
    // Not through a link, and the file that opened must be the one that was read: someone who
    // can write the folder could have swapped another in.
    faults.called(.open)
    let source = open(original, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard source >= 0 else { throw systemError(original, .unreadable, FileFailure.open) }
    defer {
        faults.called(.close)
        close(source)
    }
    faults.called(.metadata)
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
        faults.called(.clone(bytes: identity.size))
        if fclonefileat(source, folder, name, 0) == 0 {
            cloned = true
        } else if errno != ENOTSUP && errno != EXDEV {
            throw systemError(original, .writeFailed, "can't clone it to \(temp)")
        }
    }
    faults.called(.open)
    let destination = openTemp(name, in: folder, cloned: cloned)
    guard destination >= 0 else {
        let error = systemError(original, .writeFailed, "can't create the temp file \(temp)")
        if cloned { unlinkat(folder, name, 0) }
        throw error
    }
    do throws(TagWriteError) {
        var isOpen = true
        defer { if isOpen { close(destination) } }
        faults.called(.metadata)
        try requireOwnTemp(destination, name, in: folder, device: info.st_dev, original)
        if cloned {
            faults.called(.metadata)
            guard ftruncate(destination, off_t(total)) == 0 else {
                throw systemError(original, .writeFailed, "can't size the temp file")
            }
            for (offset, segment) in placed {
                if case .bytes(let bytes) = segment {
                    try writeAll(bytes, to: destination, at: offset, original, faults)
                }
            }
        } else {
            for (offset, segment) in placed {
                switch segment {
                case .bytes(let bytes):
                    try writeAll(bytes, to: destination, at: offset, original, faults)
                case .original(let range):
                    try copy(range, from: source, to: destination, at: offset, original, faults)
                }
            }
        }
        // The attributes go first, so the flush covers them too before the rename.
        try copyAttributes(from: source, info, to: destination, original, faults)
        faults.called(.flushDrive)
        try flush(destination, original, .writeFailed)
        faults.called(.metadata)
        var written = stat()
        guard fstat(destination, &written) == 0 else {
            throw systemError(original, .writeFailed, "can't stat the temp file")
        }
        // An SMB server sets a written file's mtime when its handle closes (MS-FSA 2.1.5.4), so
        // the identity the rename is checked against is taken after the close, by name, once
        // the name is known to still hold the file written here.
        isOpen = false
        faults.called(.close)
        guard close(destination) == 0 else {
            throw systemError(original, .writeFailed, "can't close the temp file")
        }
        if let hook = faults.whenTempCloses {
            do {
                try hook(temp)
            } catch {
                throw TagWriteError(path: original, kind: .writeFailed, detail: "\(error)")
            }
        }
        faults.called(.metadata)
        var closed = stat()
        guard fstatat(folder, name, &closed, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw systemError(original, .writeFailed, "can't stat the temp file")
        }
        guard closed.st_mode & S_IFMT == S_IFREG, closed.st_nlink == 1,
            closed.st_dev == written.st_dev, closed.st_ino == written.st_ino
        else {
            throw TagWriteError(path: original, kind: .changedDuringWrite, detail: tempSwapDetail)
        }
        return TempFile(path: temp, identity: FileIdentity(closed))
    } catch {
        unlinkat(folder, name, 0)
        throw error
    }
}

/// Removes the temp files earlier writes of `paths` left, as a crash before a rename does,
/// listing each folder once however many of its files a batch writes (ADR 0108). Returns why,
/// for each path whose folder couldn't be listed or whose leftovers couldn't be removed.
func removeLeftoverTemps(for paths: [String], _ faults: WriteFaults) -> [String: TagWriteError] {
    var failures: [String: TagWriteError] = [:]
    let byFolder = Dictionary(grouping: Set(paths)) { ($0 as NSString).deletingLastPathComponent }
    for (folder, files) in byFolder {
        faults.called(.list)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder)
        } catch {
            for path in files {
                failures[path] = TagWriteError(
                    path: path, kind: .writeFailed, detail: "can't list its folder: \(error)")
            }
            continue
        }
        for path in files {
            for name in names where isTemp(name, of: path) {
                faults.called(.remove)
                guard unlink(folder + "/" + name) == 0 || errno == ENOENT else {
                    failures[path] = systemError(
                        path, .writeFailed, "can't remove the old temp file \(folder)/\(name)")
                    break
                }
            }
        }
    }
    return failures
}

let replacedDetail = "something else replaced the file while its tags were written"
let changedDetail = "something else changed the file while its tags were written"

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
    else {
        logger.error(
            "the temp file of \(original) was \(String(describing: temp.identity)) once written and is \(String(describing: FileIdentity(info))), \(info.st_nlink) links, before the rename"
        )
        throw TagWriteError(path: original, kind: .changedDuringWrite, detail: tempChangedDetail)
    }
}

let tempChangedDetail = "something else changed the temp file before it replaced the original"

private func writeAll(
    _ bytes: [UInt8], to descriptor: Int32, at offset: Int, _ path: String,
    _ faults: WriteFaults
) throws(TagWriteError) {
    faults.called(.write(bytes: bytes.count))
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
    _ path: String, _ faults: WriteFaults
) throws(TagWriteError) {
    var buffer = [UInt8](repeating: 0, count: min(copyBytes, range.count))
    var done = 0
    while done < range.count {
        let want = min(buffer.count, range.count - done)
        faults.called(.read(bytes: want))
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
        try writeAll(Array(buffer[0..<count]), to: destination, at: offset + done, path, faults)
        done += count
    }
}

/// Extended attributes macOS manages itself, which a volume may refuse to set on a new file
/// although the file it was read from has them; a refusal of one leaves it off the new file
/// (ADR 0136). The quarantine flag of a downloaded file means nothing on audio. Any other
/// refusal fails the write, so a Finder tag or an attribute of the owner's is never dropped.
let unsettableAttributes: Set<String> = ["com.apple.provenance", "com.apple.quarantine"]

/// The errors a volume answers with when it won't set an attribute.
private let refusals: Set<Int32> = [EACCES, EPERM, ENOTSUP]

/// Everything but the data and the mtime, so the edited file keeps the original's attributes.
private func copyAttributes(
    from source: Int32, _ info: stat, to destination: Int32, _ path: String,
    _ faults: WriteFaults
) throws(TagWriteError) {
    // The ACL, the list of extended attributes, then the mode, the creation date and the
    // flags; each attribute adds its own read and write below.
    for _ in 0..<5 { faults.called(.metadata) }
    let refusal = faults.refusingAttribute?("acl")
    if let refusal { errno = refusal }
    guard refusal == nil, fcopyfile(source, destination, nil, copyfile_flags_t(COPYFILE_ACL)) == 0
    else { throw systemError(path, .writeFailed, "can't copy its ACL") }
    try copyExtendedAttributes(from: source, to: destination, path, faults)
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

/// Copies each extended attribute on its own, rather than in one `fcopyfile`, so a refusal
/// names the attribute, and one in `faults.unsettable` can be left off.
private func copyExtendedAttributes(
    from source: Int32, to destination: Int32, _ path: String, _ faults: WriteFaults
) throws(TagWriteError) {
    for name in try attributeNames(source, path) {
        faults.called(.metadata)
        let size = fgetxattr(source, name, nil, 0, 0, 0)
        var value = [UInt8](repeating: 0, count: max(0, size))
        let read = size < 0 ? size : fgetxattr(source, name, &value, value.count, 0, 0)
        guard read >= 0 else {
            throw systemError(path, .unreadable, "can't read its extended attribute \(name)")
        }
        faults.called(.metadata)
        let refusal = faults.refusingAttribute?(name)
        if let refusal { errno = refusal }
        guard refusal != nil || fsetxattr(destination, name, value, read, 0, 0) != 0 else {
            continue
        }
        guard faults.unsettable.contains(name), refusals.contains(errno) else {
            throw systemError(path, .writeFailed, "can't copy the extended attribute \(name)")
        }
        logger.notice(
            "left the extended attribute \(name) off the new file of \(path), which the volume refused: \(String(cString: strerror(errno)))"
        )
    }
}

/// The names of the extended attributes of the file open as `descriptor`.
private func attributeNames(_ descriptor: Int32, _ path: String) throws(TagWriteError)
    -> [String]
{
    let size = flistxattr(descriptor, nil, 0, 0)
    var names = [CChar](repeating: 0, count: max(0, size))
    let listed = size <= 0 ? size : flistxattr(descriptor, &names, names.count, 0)
    guard listed >= 0 else {
        throw systemError(path, .unreadable, "can't list its extended attributes")
    }
    return names[0..<listed].split(separator: 0).map {
        String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Renames `temp` over `original`, then flushes the folder so the rename survives a crash.
func replace(_ original: String, with temp: String, _ faults: WriteFaults) throws(TagWriteError) {
    faults.called(.rename)
    guard rename(temp, original) == 0 else {
        let error = systemError(original, .writeFailed, "can't replace it with the temp file")
        unlink(temp)
        throw error
    }
    // The folder's open, flush and close.
    for call in [FileCall.open, .flush, .close] { faults.called(call) }
    let folder = open((original as NSString).deletingLastPathComponent, O_RDONLY | O_CLOEXEC)
    // The rename is done either way; a folder that can't be flushed (some network volumes)
    // only loses the guarantee that it survives a power cut, so it's logged, not thrown.
    if folder < 0 || fsync(folder) != 0 {
        logger.notice(
            "couldn't flush the folder of \(original): \(String(cString: strerror(errno)))")
    }
    if folder >= 0 { close(folder) }
}
