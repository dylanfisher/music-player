import Darwin
import Foundation
import Log
import Metadata

private let logger = moduleLogger()

/// The file system calls a move into the library folder makes, which tests replace to take the
/// fallback, fail a rename partway, or put the folders on two volumes.
struct MoveCalls: Sendable {
    /// `renamex_np` with `RENAME_EXCL`: 0, or the `errno` it set.
    var renameExclusive: @Sendable (String, String) -> Int32 = { from, to in
        renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
    }
    /// `rename(2)`: 0, or the `errno` it set.
    var rename: @Sendable (String, String) -> Int32 = { from, to in
        Darwin.rename(from, to) == 0 ? 0 : errno
    }
    /// The volume `path` is on, its `st_dev`; nil when it can't be stat'ed.
    var volume: @Sendable (String) -> dev_t? = { path in
        var info = stat()
        return stat(path, &info) == 0 ? info.st_dev : nil
    }
}

/// Renames a staged album's files into the library folder (ADR 0147), each at the path its
/// tags give it (ADR 0124), never over a file. Every step is in the index's ledger before it's
/// taken and can be worked out again from the file system, so a crash, or another Mac, resumes
/// it. Calls block on the volumes, so make them off the main thread.
package struct LibraryFolderMove: Sendable {
    /// One staged file's move.
    struct Planned: Equatable, Sendable {
        /// Relative to the staging folder.
        var stagedPath: String
        var source: String
        var destination: String
        /// What the file must measure, where it is and where it goes.
        var sizeBytes: Int
    }

    /// The staging folder as found.
    let stagingRoot: String
    /// `library.folder`.
    let libraryFolder: String
    /// Where the library's share is mounted: the ledger keeps library paths relative to it,
    /// as an upgrade job keeps its old files, so they resolve on any Mac.
    let shareRoot: String
    var calls = MoveCalls()

    package init(stagingRoot: String, libraryFolder: String, shareRoot: String) {
        self.stagingRoot = stagingRoot
        self.libraryFolder = libraryFolder
        self.shareRoot = shareRoot
    }

    init(stagingRoot: String, libraryFolder: String, shareRoot: String, calls: MoveCalls) {
        self.init(stagingRoot: stagingRoot, libraryFolder: libraryFolder, shareRoot: shareRoot)
        self.calls = calls
    }

    /// Where each of `files` of the staged folder `folder` goes, in the files' order, for the
    /// Approve sheet to list: a first run's checks, refusing as it would, with nothing moved.
    /// A destination taken by one of `replacing`, an upgrade's old files, isn't refused.
    package func destinations(
        folder: String, files: [(name: String, sizeBytes: Int)], replacing: Set<String> = []
    ) throws -> [String] {
        try plan(folder: folder, files: files, replacing: replacing, try checkedRoots())
            .map(\.destination)
    }

    /// Moves the files `files` of the staged folder `folder` into the library folder, for the
    /// job `job` of the release `release`, and returns their new paths in the files' order.
    /// A first run works out every destination first and refuses the whole album, moving
    /// nothing, when any is taken; a run after that takes the destinations from the ledger and
    /// does what's left. A destination that's a key of `asides`, an upgrade's old file the new
    /// one replaces at its own path, isn't taken: the old file is renamed to its value first.
    func moveIn(
        job: Int, release: Int, folder: String, files: [(name: String, sizeBytes: Int)],
        asides: [String: String] = [:], ledger index: LibraryIndex
    ) throws -> [String] {
        let roots = try checkedRoots()
        let ledgered = try index.importSteps(job: job).filter { $0.kind == .moved }
        let planned: [Planned]
        if ledgered.isEmpty {
            planned = try plan(
                folder: folder, files: files, replacing: Set(asides.keys.map(nfc)), roots)
            try index.database.transaction {
                for move in planned {
                    try index.recordImportStep(
                        ImportStep(
                            jobID: job, releaseID: release, kind: .moved, path: move.stagedPath,
                            destination: try shareRelative(move.destination),
                            sizeBytes: move.sizeBytes))
                }
            }
        } else {
            planned = try resumed(folder: folder, files: files, ledgered)
        }
        let asides = Dictionary(
            asides.map { (nfc($0.key), $0.value) }, uniquingKeysWith: { one, _ in one })
        for move in planned { try take(move, aside: asides[nfc(move.destination)], roots) }
        return planned.map(\.destination)
    }

    /// The staging and library folders with every symbolic link followed, once each is found,
    /// apart and on one volume.
    private func checkedRoots() throws(MoveRefusal) -> (staging: String, library: String) {
        guard let staging = resolved(stagingRoot) else { throw .notFound(stagingRoot) }
        guard let library = resolved(libraryFolder) else { throw .notFound(libraryFolder) }
        if stagingOverlap(staging, [library]) != nil {
            throw .overlap(staging: stagingRoot, library: libraryFolder)
        }
        guard isPath(libraryFolder, under: shareRoot) else {
            throw .outsideShare(libraryFolder, shareRoot)
        }
        guard let one = calls.volume(staging), let other = calls.volume(library), one == other
        else { throw .otherVolume(staging: stagingRoot, library: libraryFolder) }
        return (staging, library)
    }

    /// Each file's move on a first run, refused whole when a destination is taken by a file
    /// not in `replacing`, two files share one, or a file isn't what was staged.
    private func plan(
        folder: String, files: [(name: String, sizeBytes: Int)], replacing: Set<String>,
        _ roots: (staging: String, library: String)
    ) throws -> [Planned] {
        var planned: [Planned] = []
        var taken: [String] = []
        var seen: Set<String> = []
        for file in files {
            let stagedPath = folder + "/" + file.name
            let source = stagingRoot + "/" + stagedPath
            guard pathExists(source) else { throw MoveRefusal.notStaged(source) }
            try checkSource(source, roots.staging)
            let size = sizeOf(source)
            guard size == file.sizeBytes else {
                throw MoveRefusal.wrongSize(source, found: size, expected: file.sizeBytes)
            }
            let tags: TrackTags
            do {
                tags = try readMetadata(at: URL(fileURLWithPath: source, isDirectory: false))
                    .metadata.tags
            } catch {
                throw MoveRefusal.unreadable(source, "\(error)")
            }
            let destination = try listedPath(
                libraryFolderPath(for: tags, of: source), in: libraryFolder)
            let key = nfc(destination)
            if (pathExists(destination) && !replacing.contains(key)) || seen.contains(key) {
                taken.append(destination)
            }
            seen.insert(key)
            planned.append(
                Planned(
                    stagedPath: stagedPath, source: source, destination: destination,
                    sizeBytes: file.sizeBytes))
        }
        guard taken.isEmpty else { throw MoveRefusal.collisions(taken) }
        return planned
    }

    /// The moves the ledger holds, in the files' order; every file must have one.
    private func resumed(
        folder: String, files: [(name: String, sizeBytes: Int)], _ ledgered: [ImportStep]
    ) throws(MoveRefusal) -> [Planned] {
        let byPath = Dictionary(ledgered.map { ($0.path, $0) }, uniquingKeysWith: { one, _ in one })
        return try files.map { file throws(MoveRefusal) in
            let stagedPath = folder + "/" + file.name
            guard let step = byPath[stagedPath], let destination = step.destination else {
                throw .notLedgered(stagedPath)
            }
            return Planned(
                stagedPath: stagedPath, source: stagingRoot + "/" + stagedPath,
                destination: shareRoot + "/" + destination, sizeBytes: step.sizeBytes ?? -1)
        }
    }

    /// Renames `move`'s file unless it's already where it goes, as the file system says. With
    /// `aside`, a file at the destination is the old one it replaces, renamed there first.
    private func take(
        _ move: Planned, aside: String?, _ roots: (staging: String, library: String)
    ) throws(MoveRefusal) {
        let sourceThere = pathExists(move.source)
        var destinationThere = pathExists(move.destination)
        if sourceThere, destinationThere, let aside, !pathExists(aside) {
            try checkDestination((aside as NSString).deletingLastPathComponent, roots.library)
            try rename(move.destination, to: aside)
            destinationThere = false
        }
        switch (sourceThere, destinationThere) {
        case (false, true):
            // Moved by a run before.
            let size = sizeOf(move.destination)
            guard size == move.sizeBytes else {
                throw .wrongSize(move.destination, found: size, expected: move.sizeBytes)
            }
            return
        case (true, true): throw .collisions([move.destination])
        case (false, false): throw .lost(move.source, move.destination)
        case (true, false): break
        }
        try checkSource(move.source, roots.staging)
        let parent = (move.destination as NSString).deletingLastPathComponent
        try checkDestination(parent, roots.library)
        do {
            try FileManager.default.createDirectory(
                atPath: parent, withIntermediateDirectories: true)
        } catch {
            throw .failed(move.source, move.destination, error.localizedDescription)
        }
        try checkDestination(parent, roots.library)
        try rename(move.source, to: move.destination)
    }

    /// Renames `source` to `destination`, never over a file.
    private func rename(_ source: String, to destination: String) throws(MoveRefusal) {
        switch renameNeverOver(source, to: destination, calls) {
        case 0: return
        case EEXIST: throw .collisions([destination])
        case EXDEV: throw .otherVolume(staging: stagingRoot, library: libraryFolder)
        case let code: throw .failed(source, destination, errorText(code))
        }
    }

    /// Refuses `source` unless it's inside the staging folder once its links are followed.
    private func checkSource(_ source: String, _ staging: String) throws(MoveRefusal) {
        guard let real = resolved(source), isPath(real, under: staging) else {
            throw .outsideStaging(source)
        }
    }

    /// Refuses the folder `parent` unless it's in the library folder `library`.
    private func checkDestination(_ parent: String, _ library: String) throws(MoveRefusal) {
        guard isFolder(parent, in: library) else { throw .outsideLibrary(parent) }
    }

    /// `path` relative to the share's mount point.
    private func shareRelative(_ path: String) throws(MoveRefusal) -> String {
        guard isPath(path, under: shareRoot) else { throw .outsideShare(path, shareRoot) }
        return String(path.dropFirst(stem(shareRoot).count + 1))
    }
}

/// Why an album wasn't moved, or was moved only in part, into the library folder.
enum MoveRefusal: Error, Equatable, CustomStringConvertible {
    /// Files already at these destinations, or two of the album's files with one.
    case collisions([String])
    case otherVolume(staging: String, library: String)
    case overlap(staging: String, library: String)
    case notFound(String)
    case outsideStaging(String)
    case outsideLibrary(String)
    /// The library folder, or a destination, isn't under where the share is mounted.
    case outsideShare(String, String)
    case wrongSize(String, found: Int?, expected: Int)
    case unreadable(String, String)
    /// The ledger has no destination for a staged file.
    case notLedgered(String)
    /// A first run found a file gone from the staging folder: a run on another Mac, whose
    /// ledger this one doesn't have, may have moved it.
    case notStaged(String)
    /// The file is neither where it was staged nor where it went.
    case lost(String, String)
    case failed(String, String, String)

    var description: String {
        switch self {
        case .collisions(let paths):
            "already in the library: " + paths.joined(separator: ", ")
        case .otherVolume(let staging, let library):
            "the staging folder \(staging) and the library folder \(library) are on different"
                + " volumes, so a move would be a copy and a delete"
        case .overlap(let staging, let library):
            "the staging folder \(staging) and the library folder \(library) overlap"
        case .notFound(let path): "\(path) can't be found"
        case .outsideStaging(let path): "\(path) isn't inside the staging folder"
        case .outsideLibrary(let path): "\(path) isn't inside the library folder"
        case .outsideShare(let path, let share): "\(path) isn't under the share at \(share)"
        case .wrongSize(let path, let found, let expected):
            "\(path) is \(found.map { "\($0) bytes" } ?? "missing"), not \(expected) bytes"
        case .unreadable(let path, let detail): "\(path)'s tags don't read: \(detail)"
        case .notLedgered(let path): "the import's steps don't say where \(path) goes"
        case .notStaged(let path):
            "\(path) is no longer staged, and this Mac has no record of where it went; resume"
                + " on the Mac that started the import"
        case .lost(let source, let destination):
            "\(source) is neither in the staging folder nor at \(destination)"
        case .failed(let source, let destination, let detail):
            "couldn't move \(source) to \(destination): \(detail)"
        }
    }
}

/// Held around the check and the rename where a share refuses `RENAME_EXCL`, so the app's two
/// writers of the library folder, Approve and Keep Files Organized, can't both find a name free.
private let fallbackRenames = NSLock()

/// Renames `source` to `destination` with `calls`, never over a file: 0, else the `errno`, with
/// `EEXIST` for a file in the way. A share that refuses `RENAME_EXCL` (`ENOTSUP` or `EINVAL`)
/// gets an `lstat` and a plain rename under a lock: the app is the library folder's only
/// writer, so nothing of its own comes between them (ADR 0147, ADR 0160).
func renameNeverOver(_ source: String, to destination: String, _ calls: MoveCalls) -> Int32 {
    let code = calls.renameExclusive(source, destination)
    guard code == ENOTSUP || code == EINVAL else { return code }
    logger.notice(
        "the volume refused RENAME_EXCL for \(destination); checking with lstat and renaming")
    return fallbackRenames.withLock {
        var info = stat()
        if lstat(destination, &info) == 0 { return EEXIST }
        let missing = errno
        guard missing == ENOENT else { return missing }
        return calls.rename(source, destination)
    }
}

/// `relative`, a path in `libraryFolder`, with each part that's there named as its folder
/// lists it. On a volume that ignores case, such as the NAS, a part the tags spell in another
/// case is the same file or folder, and the index and the move list know it by the name it
/// has.
func listedPath(_ relative: String, in libraryFolder: String) throws -> String {
    let ignoresCase = pathconf(libraryFolder, _PC_CASE_SENSITIVE) == 0
    var path = libraryFolder
    var listing = true
    for part in relative.split(separator: "/").map(String.init) {
        if listing, ignoresCase {
            let names = try FileManager.default.contentsOfDirectory(atPath: path)
            if let listed = names.first(where: {
                $0.compare(part, options: .caseInsensitive) == .orderedSame
            }) {
                path += "/" + listed
                listing = pathIsDirectory(path)
                continue
            }
            listing = false
        }
        path += "/" + part
    }
    return path
}

/// Whether the part of the folder `folder` that exists, its links followed, is `library` (the
/// library folder, resolved) or inside it. The rest are names `libraryFolderPath` made, which
/// hold no `..`.
func isFolder(_ folder: String, in library: String) -> Bool {
    var existing = folder
    while !pathExists(existing), existing != "/" {
        existing = (existing as NSString).deletingLastPathComponent
    }
    guard let real = resolved(existing) else { return false }
    return real == library || isPath(real, under: library)
}

func nfc(_ path: String) -> String { path.precomposedStringWithCanonicalMapping }

func pathIsDirectory(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
}

/// Whether anything is at `path`, a symbolic link included.
func pathExists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

func sizeOf(_ path: String) -> Int? {
    var info = stat()
    return lstat(path, &info) == 0 ? Int(info.st_size) : nil
}

/// `path` with every symbolic link followed and `.` and `..` gone; nil when it doesn't exist.
func resolved(_ path: String) -> String? {
    guard let real = realpath(path, nil) else { return nil }
    defer { free(real) }
    return String(cString: real)
}

func errorText(_ code: Int32) -> String { String(cString: strerror(code)) }
