import Foundation
import Metadata
import TagWriter

/// Every edit of docs/plan.md's phase 11 on every clone, each checked and undone, then the
/// failure injections. The clones must have just been made from `reference`.
struct RoundTrip {
    let reference: URL
    let clones: URL
    /// Where `scripts/tag-corpus` attached the small disk image, for the full-disk test.
    let fullDisk: URL?
    let roots: [URL]
    var writer: TagWriter
    var files = 0
    var edits = 0
    /// Printed as each is found, so a run cut short still shows them.
    var failures: [String] = [] {
        didSet {
            for failure in failures.dropFirst(oldValue.count) {
                print("FAILED \(failure)", to: &standardError)
            }
        }
    }
    /// Containers whose metadata AVFoundation doesn't read, so it can't confirm their edits.
    var unreadByAVFoundation: Set<String> = []

    init(reference: URL, clones: URL, fullDisk: URL?) throws {
        self.reference = reference
        self.clones = clones
        self.fullDisk = fullDisk
        roots = try writableRoots()
        let journal = clones.appendingPathComponent(".undo")
        try requireCorpusWrite(journal.path, roots: roots)
        writer = TagWriter(journal: TagUndoJournal(dataDirectory: journal))
    }

    mutating func run() throws {
        let originals = try audioFiles(in: reference)
        var folders: [URL: [URL]] = [:]
        for original in originals {
            files += 1
            let clone = cloneURL(original)
            folders[clone.deletingLastPathComponent(), default: []].append(clone)
            // Each file's images and AVFoundation objects go before the next, over hours of run.
            autoreleasepool {
                do {
                    try checkClone(original, clone)
                    for (name, edit) in try plannedEdits(original) {
                        try roundTrip(name, edit, [clone])
                    }
                } catch {
                    failures.append("\(relative(original)): \(error)")
                }
            }
            print("\(files)/\(originals.count) \(relative(original))", to: &standardError)
        }
        for (folder, members) in folders.sorted(by: { $0.key.path < $1.key.path }) {
            do {
                try roundTrip(
                    "batch album", TagEdit(values: [.album: "Batch \(folder.lastPathComponent)"]),
                    members)
            } catch {
                failures.append("\(folder.path): batch: \(error)")
            }
        }
        try injectFailures(originals)
    }

    // MARK: Edits

    private func plannedEdits(_ original: URL) throws -> [(String, TagEdit)] {
        let parsed = try readMetadata(at: original)
        let tags = parsed.metadata.tags
        let layout = try readTagLayout(at: original)
        let title = tags.title ?? original.deletingPathExtension().lastPathComponent
        let artBytes = parsed.metadata.art?.byteCount ?? 100_000
        var result: [(String, TagEdit)] = [
            ("same-length title", TagEdit(values: [.title: String(title.reversed())])),
            (
                "shorter title",
                TagEdit(values: [.title: String(title.prefix(max(1, title.count / 2)))])
            ),
            (
                "title past the padding",
                TagEdit(values: [
                    .title: String(repeating: "Long ", count: layout.paddingBytes / 5 + 200)
                ])
            ),
            ("non-ASCII title", TagEdit(values: [.title: "Perälä"])),
        ]
        let present: [(TagEditField, String?)] = [
            (.genre, tags.genre), (.comment, tags.comment), (.album, tags.album),
        ]
        if let (field, _) = present.first(where: { $0.1 != nil }) {
            result.append(("cleared \(field.rawValue)", TagEdit(values: [field: ""])))
        }
        let absent: [(TagEditField, String?)] = [
            (.composer, tags.composer), (.comment, tags.comment), (.albumArtist, tags.albumArtist),
            (.date, tags.date), (.genre, tags.genre),
        ]
        if let (field, _) = absent.first(where: { $0.1 == nil }) {
            result.append(
                ("added \(field.rawValue)", TagEdit(values: [field: "Added by the round trip"])))
        }
        // Larger art: random pixels, so its size follows its area.
        let side = Int((Double(artBytes) * 1.5 / 2).squareRoot()) + 64
        result += [
            (
                "larger art",
                TagEdit(art: .replace(try noiseJPEG(side: side), mimeType: jpegMIMEType))
            ),
            (
                "smaller art",
                TagEdit(art: .replace(try noiseJPEG(side: 16), mimeType: jpegMIMEType))
            ),
            ("removed art", TagEdit(art: .remove)),
        ]
        return result
    }

    /// Writes `edit` to `clones`, checks each, undoes it and checks each matches its original.
    private mutating func roundTrip(_ name: String, _ edit: TagEdit, _ clones: [URL]) throws {
        for clone in clones { try requireCorpusWrite(clone.path, roots: roots) }
        let attributes = try clones.map(fileAttributes)
        let report = writer.write(edit, to: clones.map(\.path))
        edits += clones.count
        for failure in report.failures { failures.append("\(name): \(failure)") }
        for clone in clones where report.changed.contains(clone.path) {
            do {
                try check(clone, after: edit, attributes: attributes[clones.firstIndex(of: clone)!])
            } catch {
                failures.append("\(relative(clone)): \(name): \(error)")
            }
        }
        let undo = writer.undoLast()
        for failure in undo.failures { failures.append("undoing \(name): \(failure)") }
        for (index, clone) in clones.enumerated() {
            if try !sameBytes(original(of: clone), clone) {
                failures.append("\(relative(clone)): undoing \(name) didn't restore it")
            }
            if try fileAttributes(clone) != attributes[index] {
                failures.append("\(relative(clone)): undoing \(name) changed its attributes")
            }
        }
    }

    /// The checks of docs/plan.md's phase 11, step 4, on one edited clone.
    private mutating func check(_ clone: URL, after edit: TagEdit, attributes: [String]) throws {
        let original = original(of: clone)
        let originalParsed = try readMetadata(at: original)
        let expected = try edit.applied(to: originalParsed.metadata.tags)
        var problems: [String] = []

        let before = try readTagLayout(at: original)
        let after = try readTagLayout(at: clone)
        if try sha256(original, ranges: before.payload) != sha256(clone, ranges: after.payload) {
            problems.append("the audio payload changed")
        }
        let reread = try readMetadata(at: clone)
        if reread.metadata.tags != expected {
            problems.append("our reader reads \(reread.metadata.tags), not \(expected)")
        }
        let expectedArt: Data? =
            switch edit.art {
            case .replace(let image, _): image
            case .remove: nil
            case nil: try originalParsed.metadata.art.map { try readArt($0, at: original) }
            }
        if try reread.metadata.art.map({ try readArt($0, at: clone) }) != expectedArt {
            problems.append("our reader's art isn't what was written")
        }

        let avBefore = AVTags(original)
        let avAfter = AVTags(clone)
        if avBefore.title == nil, avBefore.artist == nil, avBefore.album == nil {
            unreadByAVFoundation.insert(before.container.rawValue)
        } else {
            var wanted = avBefore
            if edit.values[.title] != nil { wanted.title = expected.title }
            if edit.values[.album] != nil { wanted.album = expected.album }
            if edit.art != nil { wanted.artwork = expectedArt }
            if avAfter != wanted {
                problems.append("AVFoundation reads \(describe(avAfter)), not \(describe(wanted))")
            }
        }
        if try audioDescription(clone) != audioDescription(original) {
            problems.append("afinfo describes the audio differently")
        }
        problems += try untouchedBlockDifferences(original: original, edited: clone, edit: edit)
        if try fileAttributes(clone) != attributes { problems.append("its attributes changed") }
        if !problems.isEmpty { throw CorpusError(problems.joined(separator: "; ")) }
    }

    // MARK: Failure injection

    private mutating func injectFailures(_ originals: [URL]) throws {
        // The first file of each container, by path.
        var picked: [String: URL] = [:]
        for original in originals {
            let container = try readTagLayout(at: original).container.rawValue
            if picked[container] == nil { picked[container] = original }
        }
        let edit = TagEdit(values: [.title: "Injected"])
        for (container, original) in picked.sorted(by: { $0.key < $1.key }) {
            let clone = cloneURL(original)
            try requireCorpusWrite(clone.path, roots: roots)
            let attributes = try fileAttributes(clone)
            var info = stat()
            guard stat(clone.path, &info) == 0 else {
                throw CorpusError("can't stat \(clone.path)")
            }

            chmod(clone.path, 0o400)
            expectFailure(
                "\(container) read-only", writer.write(edit, to: [clone.path]), .notWritable, clone)
            chmod(clone.path, info.st_mode & 0o7777)

            var crashing = writer
            crashing.faults.crashBeforeRename = true
            _ = crashing.write(edit, to: [clone.path])
            edits += 1
            if try !sameBytes(original, clone) {
                failures.append("\(container) crash: the original changed")
            }
            let temp = clone.deletingLastPathComponent().appendingPathComponent(
                ".\(clone.lastPathComponent).tagwrite")
            if !FileManager.default.fileExists(atPath: temp.path) {
                failures.append("\(container) crash: no temp file was left to show the crash")
            }
            // The next write replaces the leftover temp file; undo puts the clone back.
            let recovered = writer.write(edit, to: [clone.path])
            if recovered.changed != [clone.path] {
                failures.append("\(container) after a crash: \(recovered.failures)")
            }
            let undo = writer.undoLast()
            if undo.changed != [clone.path] {
                failures.append("\(container) undo after a crash: \(undo.failures)")
            }
            if FileManager.default.fileExists(atPath: temp.path) {
                failures.append("\(container) after a crash: the temp file is still there")
            }

            var changing = writer
            let size = try FileManager.default.attributesOfItem(atPath: clone.path)[.size] as! Int
            let roots = self.roots
            changing.faults.beforeReplacing = { path, _ in
                try requireCorpusWrite(path, roots: roots)
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0]))
                try handle.close()
            }
            let changed = changing.write(edit, to: [clone.path])
            edits += 1
            if changed.failures.map(\.kind) != [.changedDuringWrite] {
                failures.append("\(container) changed during the write: \(changed)")
            }
            truncate(clone.path, off_t(size))
            if try !sameBytes(original, clone) {
                failures.append(
                    "\(container) changed during the write: the file isn't the original plus the other writer's byte"
                )
            }
            if try fileAttributes(clone) != attributes {
                failures.append("\(container) failure injection changed its attributes")
            }
        }
        if let fullDisk { try fillTheDisk(fullDisk, originals) }
    }

    private mutating func expectFailure(
        _ name: String, _ report: TagWriteReport, _ kind: TagWriteError.Kind, _ clone: URL
    ) {
        edits += 1
        if report.failures.map(\.kind) != [kind] || !report.changed.isEmpty {
            failures.append("\(name): expected \(kind), got \(report)")
        }
        do {
            if try !sameBytes(original(of: clone), clone) {
                failures.append("\(name): the original changed")
            }
        } catch {
            failures.append("\(name): \(error)")
        }
    }

    /// Copies the smallest corpus file onto the disk image, fills the rest, and edits it so the
    /// temp file can't be written. The copy must come through untouched, with no temp file.
    private mutating func fillTheDisk(_ mount: URL, _ originals: [URL]) throws {
        let sizes = try originals.map {
            ($0, try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as! Int)
        }
        guard let (original, size) = sizes.min(by: { $0.1 < $1.1 }) else { return }
        let copy = mount.appendingPathComponent(original.lastPathComponent)
        let filler = mount.appendingPathComponent("filler")
        try requireCorpusWrite(copy.path, roots: roots)
        try requireCorpusWrite(filler.path, roots: roots)
        try FileManager.default.copyItem(at: original, to: copy)
        let free =
            try mount.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
            ?? 0
        let room = free - size / 2
        guard room > 0 else {
            throw CorpusError(
                "the disk image at \(mount.path) is too small for \(original.lastPathComponent)")
        }
        FileManager.default.createFile(atPath: filler.path, contents: nil)
        let handle = try FileHandle(forWritingTo: filler)
        try handle.truncate(atOffset: UInt64(room))
        try handle.write(contentsOf: Data(count: 1))
        try handle.close()
        let layout = try readTagLayout(at: copy)
        let edit = TagEdit(values: [
            .title: String(repeating: "Full ", count: layout.paddingBytes / 5 + 200)
        ])
        let report = writer.write(edit, to: [copy.path])
        edits += 1
        if report.failures.map(\.kind) != [.writeFailed] {
            failures.append("full disk: expected a write failure, got \(report)")
        } else {
            print("full disk: \(report.failures[0].detail)", to: &standardError)
        }
        if try !sameBytes(original, copy) { failures.append("full disk: the file changed") }
        let temp = mount.appendingPathComponent(".\(copy.lastPathComponent).tagwrite")
        if FileManager.default.fileExists(atPath: temp.path) {
            failures.append("full disk: a temp file was left")
        }
    }

    // MARK: Paths

    private func cloneURL(_ original: URL) -> URL {
        clones.appendingPathComponent(relative(original))
    }

    private func original(of clone: URL) -> URL {
        reference.appendingPathComponent(String(clone.path.dropFirst(clones.path.count + 1)))
    }

    private func relative(_ url: URL) -> String {
        for base in [reference, clones] where url.path.hasPrefix(base.path + "/") {
            return String(url.path.dropFirst(base.path.count + 1))
        }
        return url.path
    }

    /// The clone must start as a byte-for-byte copy of the reference.
    private func checkClone(_ original: URL, _ clone: URL) throws {
        guard try sameBytes(original, clone) else {
            throw CorpusError("the clone isn't a copy of the reference; rerun scripts/tag-corpus")
        }
    }
}

private func describe(_ tags: AVTags) -> String {
    "title \(tags.title ?? "nil"), album \(tags.album ?? "nil"), art \(tags.artwork?.count ?? 0) B"
}

/// Progress goes to standard error, so the summary on standard output stays short.
nonisolated(unsafe) var standardError = StandardError()

struct StandardError: TextOutputStream {
    mutating func write(_ string: String) { FileHandle.standardError.write(Data(string.utf8)) }
}
