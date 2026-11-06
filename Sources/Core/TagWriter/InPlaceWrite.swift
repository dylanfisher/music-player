import Darwin
import Foundation
import Metadata

/// A write in place: the one run of bytes an edit changes in the original, when the new tags
/// fit the room the old ones had, so the file keeps its size and every other byte stays where
/// it is (ADR 0107).
struct InPlacePlan {
    var offset: Int
    var newBytes: [UInt8]
    var oldBytes: [UInt8]
    /// The file's size once written.
    var size: Int

    var region: Range<Int> { offset..<offset + newBytes.count }

    /// The plan for the file `segments` make, from the first byte that differs from the
    /// original to the last; nil when the file would have another size or a kept range would
    /// move, or when no byte changes.
    init?(
        _ segments: [Segment], size: Int, source: MeteredSource, payload: [Range<Int>], path: String
    ) throws(TagWriteError) {
        var offset = 0
        var written: [(offset: Int, bytes: [UInt8])] = []
        for segment in segments {
            switch segment {
            case .original(let range): guard range.lowerBound == offset else { return nil }
            case .bytes(let bytes): written.append((offset, bytes))
            }
            offset += segment.count
        }
        guard offset == size else { return nil }
        var lower = Int.max
        var upper = Int.min
        for (start, bytes) in written {
            let old = try read(source, start..<start + bytes.count, path)
            guard let first = bytes.indices.first(where: { bytes[$0] != old[$0] }),
                let last = bytes.indices.last(where: { bytes[$0] != old[$0] })
            else { continue }
            lower = min(lower, start + first)
            upper = max(upper, start + last + 1)
        }
        guard lower < upper else { return nil }
        let region = lower..<upper
        guard payload.allSatisfy({ !$0.overlaps(region) }) else {
            throw TagWriteError(
                path: path, kind: .checkFailed,
                detail: "the tags written in place would change the audio")
        }
        oldBytes = try read(source, region, path)
        newBytes = oldBytes
        for (start, bytes) in written {
            let overlap = (start..<start + bytes.count).clamped(to: region)
            guard !overlap.isEmpty else { continue }
            newBytes.replaceSubrange(
                overlap.lowerBound - lower..<overlap.upperBound - lower,
                with: bytes[overlap.lowerBound - start..<overlap.upperBound - start])
        }
        self.offset = lower
        self.size = size
    }

    /// The region as the journal keeps it.
    var journaled: TagUndoJournal.InPlaceRegion {
        TagUndoJournal.InPlaceRegion(
            offset: offset, oldSHA256: sha256(oldBytes), newLength: newBytes.count,
            newSHA256: sha256(newBytes))
    }

    /// How the original is put back together from the edited file: the edited file's bytes
    /// around the region, the journaled old bytes in it.
    func restore(size: Int) -> [TagUndoJournal.RestoreSegment] {
        var segments: [TagUndoJournal.RestoreSegment] = []
        if offset > 0 { segments.append(.edited(lowerBound: 0, upperBound: offset)) }
        segments.append(.old(length: oldBytes.count))
        if region.upperBound < size {
            segments.append(.edited(lowerBound: region.upperBound, upperBound: size))
        }
        return segments
    }
}

private func read(_ source: MeteredSource, _ range: Range<Int>, _ path: String)
    throws(TagWriteError) -> [UInt8]
{
    do throws(ParseFailure) {
        return try source.read(range)
    } catch {
        throw TagWriteError(path: path, kind: .unreadable, detail: error.detail)
    }
}

/// What a file holds where its write in place goes (ADR 0108).
enum RegionState {
    /// The new bytes, at the size the write leaves: it landed.
    case new
    /// The old bytes, at the original's size: it hadn't started.
    case old
    /// Neither: it was cut short.
    case torn
}

/// Reads where `record`'s write in place goes in its file, through a descriptor that doesn't
/// cache, so a network volume answers from the server. Only the region is read: the write
/// touches nothing else.
func regionState(
    _ record: TagUndoJournal.FileRecord, _ region: TagUndoJournal.InPlaceRegion,
    faults: WriteFaults
) throws(TagWriteError) -> RegionState {
    do throws(ParseFailure) {
        let source = try MeteredSource(path: record.path, faults: faults)
        func holds(_ length: Int, _ hash: Data) throws(ParseFailure) -> Bool {
            guard region.offset + length <= source.size else { return false }
            return sha256(try source.read(region.offset..<region.offset + length)) == hash
        }
        let newSize = max(record.originalSize, region.offset + region.newLength)
        if source.size == newSize, try holds(region.newLength, region.newSHA256) { return .new }
        if source.size == record.originalSize, try holds(record.oldByteCount, region.oldSHA256) {
            return .old
        }
        return .torn
    } catch {
        throw TagWriteError(
            path: record.path, kind: .unreadable, detail: error.error(path: record.path).detail)
    }
}

/// The original as the plan would leave it, so the reader can check the new tags before a
/// byte of the original is written.
struct PlannedSource: ByteSource {
    let original: MeteredSource
    let plan: InPlacePlan

    var size: Int { original.size }

    func read(_ range: Range<Int>) throws(ParseFailure) -> [UInt8] {
        var bytes = try original.read(range)
        let overlap = range.clamped(to: plan.region)
        if !overlap.isEmpty {
            bytes.replaceSubrange(
                overlap.lowerBound - range.lowerBound..<overlap.upperBound - range.lowerBound,
                with: plan.newBytes[
                    overlap.lowerBound - plan.offset..<overlap.upperBound - plan.offset])
        }
        return bytes
    }
}

/// Writes the plan's new bytes over the original at `path` with one `pwrite`, flushes them to
/// the disk and closes the file. Before writing, the open file must still be `identity` with
/// one link and hold the plan's old bytes, or another process wrote it since it was read.
/// `wrote` is set once a byte may have reached the file, so a failure after it knows the
/// original has to be put back.
func overwrite(
    _ path: String, with plan: InPlacePlan, identity: FileIdentity, faults: WriteFaults,
    wrote: inout Bool
) throws(TagWriteError) {
    faults.called(.open)
    let descriptor = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw systemError(path, .unreadable, FileFailure.open) }
    var isOpen = true
    defer { if isOpen { close(descriptor) } }
    faults.called(.metadata)
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
        throw systemError(path, .unreadable, FileFailure.stat)
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
        Int(info.st_dev) == identity.device, info.st_ino == identity.inode
    else { throw TagWriteError(path: path, kind: .changedDuringWrite, detail: replacedDetail) }
    var current = [UInt8](repeating: 0, count: plan.oldBytes.count)
    faults.called(.read(bytes: plan.oldBytes.count))
    let count = current.withUnsafeMutableBytes {
        pread(descriptor, $0.baseAddress, plan.oldBytes.count, off_t(plan.offset))
    }
    guard FileIdentity(info) == identity, count == plan.oldBytes.count, current == plan.oldBytes
    else { throw TagWriteError(path: path, kind: .changedDuringWrite, detail: changedDetail) }

    let bytes = faults.tornWriteBytes.map { Array(plan.newBytes.prefix($0)) } ?? plan.newBytes
    wrote = true
    faults.called(.write(bytes: bytes.count))
    var done = 0
    while done < bytes.count {
        let count = bytes.withUnsafeBytes {
            pwrite(
                descriptor, $0.baseAddress! + done, bytes.count - done, off_t(plan.offset + done))
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw systemError(path, .writeFailed, "can't write the tags in place")
        }
        done += count
    }
    if faults.tornWriteBytes != nil {
        throw TagWriteError(path: path, kind: .writeFailed, detail: crashDetail)
    }
    faults.called(.flush)
    try flush(descriptor, path, .writeFailed)
    isOpen = false
    faults.called(.close)
    // A network volume may report a failed write only when the file closes.
    guard close(descriptor) == 0 else {
        throw systemError(path, .writeFailed, "can't close it after writing the tags in place")
    }
}
