import Foundation
import Library
import Metadata
import Recommender

/// A job music-recommender staged, as AutoTag takes it: the release it downloaded, where, in
/// what format, and its files as the service reported them.
package struct StagedJob: Sendable {
    package var releaseID: Int
    /// As the snapshot spelled it, for a file name that starts with it.
    var artist: String
    /// The job's folder in the staging folder, one component: its `stagedPath`.
    package var folder: String
    /// The format of the folder the service downloaded.
    var format: DownloadJob.Candidate.Format
    /// In the service's order, each `name` relative to `folder`.
    var files: [DownloadJob.File]
    /// Each file's size since the player's own tag write, by name: the write can grow a file
    /// when its padding runs out, so after it the service's sizes no longer hold.
    package var tagged: [String: Int] = [:]
}

extension StagedJob {
    /// What the job's files measure under `stagingRoot` now, by name, to record after a tag
    /// write.
    package func sizesOnDisk(stagingRoot: String) throws -> [String: Int] {
        var sizes: [String: Int] = [:]
        for file in files {
            let path = stagingRoot + "/" + folder + "/" + file.name
            guard let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
            else { throw CocoaError(.fileReadUnknown) }
            sizes[file.name] = size
        }
        return sizes
    }

    /// `job` as AutoTag takes it; nil until the service has staged it in a folder.
    package init?(_ job: DownloadJob) {
        guard let folder = job.stagedFolder, let format = job.candidate?.format else { return nil }
        self.init(
            releaseID: job.release.releaseID, artist: job.release.artist, folder: folder,
            format: format, files: job.files)
    }
}

/// A staged job's files read for matching (ADR 0146): each with a synthetic negative id, so
/// none can be taken for a file in the index, and the album the matcher compares, which
/// nothing here writes.
package struct StagedAlbum: Sendable {
    /// The album's id, which no album in the index has.
    package static let albumID: Int64 = -1
    /// The largest file the service stages, which a file on the share is held to again.
    static let maxFileBytes = 2048 * 1024 * 1024

    /// In the album's order.
    package var album: DiscogsAlbum
    /// The staging folder as found.
    package var stagingRoot: String
    /// The files read, in the job's order.
    package var files: [AlbumFile]
    /// The service's file for each read one, by id.
    var staged: [Int64: DownloadJob.File]
    /// Why a file can't be matched: it's missing, unreadable, too large, or neither the size
    /// the service staged nor the one recorded after the player's tag write. Empty when every
    /// file was read.
    package var problems: [String]

    /// Reads `job`'s files under `stagingRoot`. Blocks on the reads, so call it off the main
    /// thread.
    package init(_ job: StagedJob, stagingRoot: String) {
        var problems: [String] = []
        var named: [(id: Int64, path: String)] = []
        var staged: [Int64: DownloadJob.File] = [:]
        let folder = stagingRoot + "/" + job.folder
        if !isRelativeInside(job.folder) || job.folder.contains("/") {
            problems.append("\(job.folder) isn't a folder of the staging folder")
        }
        for (index, file) in job.files.enumerated() where problems.isEmpty {
            guard isRelativeInside(file.name) else {
                problems.append("\(file.name) isn't a path inside the job's folder")
                continue
            }
            let path = folder + "/" + file.name
            let size: Int
            do {
                guard
                    let found = try FileManager.default.attributesOfItem(atPath: path)[.size]
                        as? Int
                else {
                    problems.append("\(file.name) has no size")
                    continue
                }
                size = found
            } catch {
                problems.append("\(file.name) can't be read: \(error.localizedDescription)")
                continue
            }
            if size > Self.maxFileBytes {
                problems.append("\(file.name) is over \(Self.maxFileBytes >> 20) MB")
            } else if size != file.sizeBytes && size != job.tagged[file.name] {
                problems.append(
                    "\(file.name) is \(size) bytes; the service staged \(file.sizeBytes)")
            }
            let id = -Int64(index + 1)
            named.append((id, path))
            staged[id] = file
        }
        var files: [AlbumFile] = []
        if problems.isEmpty {
            let read = readAlbumFiles(named)
            files = read.files
            problems += read.problems
        }
        self.stagingRoot = stagingRoot
        self.files = files
        self.staged = staged
        self.problems = problems
        album = Self.album(files, staged: staged, artist: job.artist)
    }

    /// The album the matcher compares: the tags as found, but a missing or junk title filled
    /// from the file's name, as the service matched it, and no release id, since an uploader's
    /// would make the matcher take the album as tagged with another release. The order is the
    /// tags' disc and track numbers when every file has them and they differ, else the number
    /// each file's name starts with, else the names'.
    private static func album(
        _ files: [AlbumFile], staged: [Int64: DownloadJob.File], artist: String
    ) -> DiscogsAlbum {
        let names = files.map { staged[$0.id]?.name ?? $0.path }
        let tagged = files.map { file in
            file.metadata.tags.trackNumber.map { [file.metadata.tags.discNumber ?? 1, $0] }
        }
        let numbered = names.map(leadingNumber)
        let order: [Int]
        if let keys = distinct(tagged) {
            order = files.indices.sorted { keys[$0].lexicographicallyPrecedes(keys[$1]) }
        } else if let keys = distinct(numbered) {
            order = files.indices.sorted { keys[$0].lexicographicallyPrecedes(keys[$1]) }
        } else {
            order = files.indices.sorted {
                names[$0].localizedStandardCompare(names[$1]) == .orderedAscending
            }
        }
        let tags = files.first?.metadata.tags
        return DiscogsAlbum(
            id: albumID, title: tags?.album ?? "", artist: tags?.albumArtist ?? tags?.artist,
            tracks: order.map { index in
                let file = files[index]
                let audio = file.metadata.audio
                let title = file.metadata.tags.title
                return DiscogsAlbum.Track(
                    fileID: file.id,
                    title: isJunk(title) ? fileTitle(names[index], artist: artist) : title,
                    seconds: audio.sampleRateHz > 0
                        ? Double(audio.lengthFrames) / Double(audio.sampleRateHz) : 0,
                    discNumber: file.metadata.tags.discNumber,
                    trackNumber: file.metadata.tags.trackNumber)
            })
    }
}

/// `keys` when every one is there and no two are the same.
private func distinct(_ keys: [[Int]?]) -> [[Int]]? {
    let found = keys.compactMap { $0 }
    return found.count == keys.count && Set(found).count == found.count ? found : nil
}

/// Whether `title` says nothing about the track: none, empty once folded, only a number, or
/// "Track 3", "Untitled", "Unknown".
private func isJunk(_ title: String?) -> Bool {
    let key = CatalogKey.matchKey(title ?? "", title: true)
    return key.isEmpty || key.allSatisfy(\.isNumber)
        || key.range(of: #"^(track|untitled|unknown)\d*$"#, options: .regularExpression) != nil
}

/// The title a file's name holds, as music-recommender reads one: the extension, a leading
/// `01`, `1-03`, `A1` or `CD2-04`, and an `Artist - ` prefix removed.
func fileTitle(_ name: String, artist: String) -> String {
    let file = (name as NSString).lastPathComponent
    let stem = (file as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces)
    var rest = Substring(stem)
    if let number = trackNumberPrefix(stem) { rest = rest.dropFirst(number.length) }
    rest = rest.drop { $0.isWhitespace || "-._)]".contains($0) }
    if let dash = rest.range(of: " - "), !artist.isEmpty,
        CatalogKey.matchKey(String(rest[..<dash.lowerBound])) == CatalogKey.matchKey(artist)
    {
        rest = rest[dash.upperBound...]
    }
    return rest.trimmingCharacters(in: .whitespaces)
}

/// The disc and track a file's name starts with: `CD2-04` is [2, 4], `1-03` [1, 3], `07`
/// [1, 7], and a vinyl side's `B2` [2, 2] for side B; nil for a name that starts with no
/// number.
private func leadingNumber(_ name: String) -> [Int]? {
    let stem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
    return trackNumberPrefix(stem.trimmingCharacters(in: .whitespaces))?.key
}

/// A leading track number in `stem`, as music-recommender reads one: `CD2-04`, `1-03`, `01`,
/// or a side's `A1` followed by a separator, so "B52s" keeps its name. Its length in
/// characters, and its disc and track.
private func trackNumberPrefix(_ stem: String) -> (length: Int, key: [Int])? {
    let characters = Array(stem)
    func digits(from start: Int) -> Int {
        var end = start
        while end < characters.count, characters[end].isASCII, characters[end].isNumber {
            end += 1
        }
        return end - start
    }
    func number(_ start: Int, _ count: Int) -> Int {
        Int(String(characters[start..<(start + count)])) ?? 0
    }
    var at = 0
    var disc: Int?
    if stem.lowercased().hasPrefix("cd"), digits(from: 2) > 0 {
        let after = 2 + digits(from: 2)
        if after < characters.count, "-. ".contains(characters[after]) {
            disc = number(2, after - 2)
            at = after + 1
        }
    }
    let first = digits(from: at)
    if first > 0 {
        var end = at + first
        if end < characters.count, "-.".contains(characters[end]), digits(from: end + 1) > 0 {
            let second = digits(from: end + 1)
            let key = [disc ?? number(at, first), number(end + 1, second)]
            end += 1 + second
            return (end, key)
        }
        return (end, [disc ?? 1, number(at, first)])
    }
    guard at < characters.count, characters[at].isASCII, characters[at].isLetter else {
        return nil
    }
    let count = digits(from: at + 1)
    let end = at + 1 + count
    guard (1...2).contains(count), end < characters.count, " -._".contains(characters[end]) else {
        return nil
    }
    let side = Int(characters[at].lowercased().unicodeScalars.first!.value) - 96
    return (end, [side, number(at + 1, count)])
}

/// Whether `path` is relative and stays inside its folder: not empty, no leading slash, and no
/// empty, `.` or `..` part.
private func isRelativeInside(_ path: String) -> Bool {
    !path.isEmpty
        && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
}

/// A staged job whose files the staged tagger writes more than once: after each write the
/// files are measured again, and `job` holds them to those sizes, since a tag write can grow a
/// file and the service's sizes were taken before it.
package final class StagedSizes: @unchecked Sendable {
    private let lock = NSLock()
    private var current: StagedJob
    private let stagingRoot: String

    package init(_ job: StagedJob, stagingRoot: String) {
        current = job
        self.stagingRoot = stagingRoot
    }

    /// The job with the sizes its files had after the last write.
    package var job: StagedJob { lock.withLock { current } }

    /// Measures the files again, after a write.
    package func wrote() throws {
        let sizes = try job.sizesOnDisk(stagingRoot: stagingRoot)
        lock.withLock { current.tagged = sizes }
    }
}
