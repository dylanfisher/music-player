import Foundation
import Log

public enum FixtureGeneration: Equatable, Sendable {
    case generated
    /// The files on disk already match the plan for this count.
    case upToDate
}

/// The size of the real library the budgets are set for.
public let fullLibraryFileCount = 43_000

/// `~/Library/Caches/MusicPlayer/fixtures`.
public func defaultFixturesDirectory() throws -> URL {
    try FileManager.default.url(
        for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
    ).appendingPathComponent("\(appDirectoryName)/fixtures")
}

/// Writes a library of `count` files under `root`, with `manifest.json` describing each one.
/// Does nothing when `root` already holds this count's files, unless `force` is set.
///
/// `root` must not exist, be empty, or hold an earlier run's output, which is deleted first. Any
/// other directory is refused, so a mistyped path can't wipe real files.
public func generateFixtures(count: Int, in root: URL, force: Bool = false) throws
    -> FixtureGeneration
{
    precondition(count > 0, "a fixture library needs at least one file")
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("fixture-seeds-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let seeds = Result { try makeSeeds(in: scratch) }
    try FileManager.default.removeItem(at: scratch)
    let renderer = Renderer(seeds: try seeds.get(), artwork: try makeArtwork())

    let plan = planLibrary(count: count)
    let manifest = FixtureManifest(
        fileCount: count, files: try renderer.renderAll(plan, writingInto: nil))
    if !force, try isCurrent(manifest, in: root) { return .upToDate }

    try prepare(root)
    let directories = Set(plan.map { ($0.path as NSString).deletingLastPathComponent })
    for directory in directories {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    _ = try renderer.renderAll(plan, writingInto: root)
    // Written last, so an interrupted run is never mistaken for a finished one.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(manifest).write(
        to: root.appendingPathComponent(FixtureManifest.fileName), options: .atomic)
    return .generated
}

private func isCurrent(_ manifest: FixtureManifest, in root: URL) throws -> Bool {
    let url = root.appendingPathComponent(FixtureManifest.fileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    // A manifest that no longer decodes was written by an older generator, so it's stale.
    guard let existing = try? loadManifest(in: root), existing == manifest else { return false }
    let files = manifest.files
    let sizesMatch = LockedArray(repeating: false, count: files.count)
    DispatchQueue.concurrentPerform(iterations: files.count) { index in
        let path = root.appendingPathComponent(files[index].path).path
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
        sizesMatch[index] = size == files[index].byteCount
    }
    return sizesMatch.values.allSatisfy { $0 }
}

private func prepare(_ root: URL) throws {
    let manager = FileManager.default
    guard manager.fileExists(atPath: root.path) else { return }
    let contents = try manager.contentsOfDirectory(atPath: root.path)
    if contents.isEmpty { return }
    guard contents.contains(FixtureManifest.fileName) else {
        throw FixtureError.refusingToClear(path: root.path)
    }
    try manager.removeItem(at: root)
}

/// Turns planned files into bytes. Holds the seeds and artwork, which every file shares.
private struct Renderer: Sendable {
    let seeds: [SeedKind: Seed]
    let artwork: [Artwork]

    /// Renders every file in parallel, writing each under `root` when it's given, and returns
    /// the manifest entries sorted by path.
    func renderAll(_ plan: [PlannedFile], writingInto root: URL?) throws -> [FixtureFile] {
        let results = LockedArray<Result<FixtureFile, any Error>?>(
            repeating: nil, count: plan.count)
        DispatchQueue.concurrentPerform(iterations: plan.count) { index in
            results[index] = Result {
                let (data, entry) = render(plan[index])
                if let root { try data.write(to: root.appendingPathComponent(entry.path)) }
                return entry
            }
        }
        return try results.values.map { try $0!.get() }.sorted { $0.path < $1.path }
    }

    func render(_ file: PlannedFile) -> (Data, FixtureFile) {
        let art = file.art.map { artwork[$0] }
        var formats: [FixtureFile.TagFormat] = []
        var expected = file.tags
        let data: Data
        switch (seeds[file.seed]!, file.layout) {
        case (.flac(let streamInfo, let frames), .vorbis(let style)):
            data = flacFile(
                streamInfo: streamInfo, frames: frames, tags: file.tags, art: art, style: style)
            if file.tags != nil { formats = [.vorbisComment] }
        case (.mp4(let seed), .mp4(let genreAsIndex)):
            data = seed.file(
                items: file.tags.map { mp4Items($0, art: art, genreAsIndex: genreAsIndex) }
                    ?? Data())
            if file.tags != nil { formats = [.mp4] }
        case (.mp3(let frames), .id3(let style)):
            let tag = file.tags.map { id3Tag($0, art: art, style: style) } ?? Data()
            data = tag + frames
            if let tags = file.tags {
                formats = [style.version.tagFormat]
                expected = id3Subset(tags, style.version)
            }
        case (.aiff(let chunks), .id3(let style)):
            var all = chunks
            if let tags = file.tags {
                all.append(riffChunk("ID3 ", id3Tag(tags, art: art, style: style), .big))
                formats = [style.version.tagFormat]
                expected = id3Subset(tags, style.version)
            }
            data = riffForm("AIFF", chunks: all, .big)
        case (.wav(let chunks), .wav(let info, let id3)):
            var all = chunks
            if let tags = file.tags {
                if info {
                    all.append(riffInfoChunk(tags))
                    formats.append(.riffInfo)
                    expected = riffInfoSubset(tags)
                }
                if let id3 {
                    all.append(riffChunk("id3 ", id3Tag(tags, art: art, style: id3), .little))
                    formats.append(id3.version.tagFormat)
                    expected = id3Subset(tags, id3.version)
                }
            }
            data = riffForm("WAVE", chunks: all, .little)
        default:
            preconditionFailure("\(file.path): layout \(file.layout) doesn't fit seed \(file.seed)")
        }

        let carriesArt = art != nil && file.tags != nil && formats != [.riffInfo]
        let entry = FixtureFile(
            path: file.path, byteCount: data.count, container: file.seed.container,
            audio: file.seed.audio, tagFormats: formats, tags: expected,
            art: carriesArt ? art?.manifestEntry : nil, malformation: nil)
        guard let malformation = file.malformation else { return (data, entry) }
        let broken = breakFile(data, malformation, path: file.path)
        return (
            broken,
            FixtureFile(
                path: file.path, byteCount: broken.count, container: file.seed.container,
                audio: nil, tagFormats: [], tags: nil, art: nil, malformation: malformation)
        )
    }
}

/// Damages a valid file the way `malformation` describes.
private func breakFile(_ data: Data, _ malformation: Malformation, path: String) -> Data {
    var data = data
    switch malformation {
    case .truncated:
        return data.prefix(data.count * 6 / 10)
    case .empty:
        return Data()
    case .garbage:
        // Seeded from the path, so reruns write the same bytes.
        var random = SplitMix64(
            seed: UInt64(truncatingIfNeeded: path.utf8.reduce(5381) { $0 &* 33 &+ Int($1) }))
        return Data((0..<4096).map { _ in UInt8.random(in: 1...255, using: &random) })
    case .flacBlockPastEnd:
        data.replaceSubrange(
            flacCommentHeaderOffset + 1..<flacCommentHeaderOffset + 4, with: [0xFF, 0xFF, 0xFF])
    case .vorbisCommentPastBlock:
        let firstField = flacCommentHeaderOffset + 4 + 4 + flacVendor.utf8.count + 4
        data.replaceSubrange(firstField..<firstField + 4, with: [0xFF, 0xFF, 0xFF, 0x7F])
    case .id3TagPastEnd:
        data.replaceSubrange(6..<10, with: [0x7F, 0x7F, 0x7F, 0x7F])
    case .id3FramePastTag:
        data.replaceBigEndian(0x0FFF_FFFF, at: id3FirstFrameSizeOffset)
    case .mp4AtomTooSmall, .mp4AtomPastParent:
        let firstItem = data.offset(of: "ilst")! + 4
        data.replaceBigEndian(malformation == .mp4AtomTooSmall ? 4 : 0x7FFF_FFF0, at: firstItem)
    case .riffChunkPastEnd:
        let size = data.offset(of: "LIST")! + 4
        data.replaceSubrange(size..<size + 4, with: [0xF0, 0xFF, 0xFF, 0x7F])
    }
    return data
}
