import Darwin
import Foundation
import Metadata

/// A write in place: the one run of bytes an edit changes in the original, when the new tags
/// fit the room the old ones had, so every byte outside the run stays where it is (ADR 0107).
/// The run may also go past the original's end, when the tags are last in the file, as in an
/// MP4 with `moov` after its audio: the file grows and nothing before the run moves (ADR 0108).
struct InPlacePlan {
    var offset: Int
    var newBytes: [UInt8]
    /// The original's bytes from `offset`, as many as `newBytes` replace: fewer when the file
    /// grows, since the original ends first.
    var oldBytes: [UInt8]
    /// The file's size once written.
    var size: Int

    var region: Range<Int> { offset..<offset + newBytes.count }

    /// The plan for the file `segments` make, from the first byte that differs from the
    /// original to the last; nil when the file would be shorter, when a kept range would move,
    /// when a file that grows would change bytes beside its audio, or when no byte changes.
    init?(
        _ segments: [Segment], size: Int, source: MeteredSource, payload: [Range<Int>], path: String
    ) throws(TagWriteError) {
        var offset = 0
        var written: [(offset: Int, bytes: [UInt8])] = []
        for segment in segments {
            switch segment {
            case .original(let range):
                // An empty range keeps nothing, as the end of a file whose tags are last.
                guard range.isEmpty || range.lowerBound == offset else { return nil }
            case .bytes(let bytes): written.append((offset, bytes))
            }
            offset += segment.count
        }
        guard offset >= size else { return nil }
        let newSize = offset
        var lower = Int.max
        var upper = Int.min
        for (start, bytes) in written {
            // Bytes past the original's end differ from it, since it has none there.
            let old =
                start < size ? try read(source, start..<min(start + bytes.count, size), path) : []
            let differs = { (index: Int) in index >= old.count || bytes[index] != old[index] }
            guard let first = bytes.indices.first(where: differs),
                let last = bytes.indices.last(where: differs)
            else { continue }
            lower = min(lower, start + first)
            upper = max(upper, start + last + 1)
        }
        guard lower < upper else { return nil }
        let region = lower..<upper
        guard payload.allSatisfy({ !$0.overlaps(region) }) else {
            // A file that grows with a header before its audio, as an AIFF whose `FORM` size
            // changes, goes through the temp file.
            if newSize > size { return nil }
            throw TagWriteError(
                path: path, kind: .checkFailed,
                detail: "the tags written in place would change the audio")
        }
        oldBytes = try read(source, lower..<min(upper, size), path)
        newBytes = oldBytes + [UInt8](repeating: 0, count: region.count - oldBytes.count)
        for (start, bytes) in written {
            let overlap = (start..<start + bytes.count).clamped(to: region)
            guard !overlap.isEmpty else { continue }
            newBytes.replaceSubrange(
                overlap.lowerBound - lower..<overlap.upperBound - lower,
                with: bytes[overlap.lowerBound - start..<overlap.upperBound - start])
        }
        self.offset = lower
        self.size = newSize
    }

    /// The region as the journal keeps it.
    var journaled: TagUndoJournal.InPlaceRegion {
        TagUndoJournal.InPlaceRegion(
            offset: offset, oldSHA256: sha256(oldBytes), newLength: newBytes.count,
            newSHA256: sha256(newBytes))
    }

    /// How the original of `size` bytes is put back together from the edited file: the edited
    /// file's bytes around the region, the journaled old bytes in it. A file that grew ends
    /// with the old bytes.
    func restore(size: Int) -> [TagUndoJournal.RestoreSegment] {
        var segments: [TagUndoJournal.RestoreSegment] = []
        if offset > 0 { segments.append(.edited(lowerBound: 0, upperBound: offset)) }
        segments.append(.old(length: oldBytes.count))
        if offset + oldBytes.count < size {
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
/// byte of the original is written. Past the original's end, only the plan has bytes.
struct PlannedSource: ByteSource {
    let original: MeteredSource
    let plan: InPlacePlan

    var size: Int { plan.size }

    func read(_ range: Range<Int>) throws(ParseFailure) -> [UInt8] {
        let kept = range.clamped(to: 0..<original.size)
        var bytes =
            (kept.isEmpty ? [] : try original.read(kept))
            + [UInt8](repeating: 0, count: range.count - kept.count)
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
