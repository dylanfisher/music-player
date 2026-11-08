import Foundation
import Testing

@testable import Discogs
@testable import Fixtures
@testable import Metadata
@testable import Settings
@testable import TagWriter

// The edits a mapping makes, written by TagWriter to generated fixtures in each tag format,
// read back as the change set meant: a second change set over the written files is empty.
// Only copies in a temp folder are written.

/// A fixture library of this target's own, apart from the other targets'.
private let library = Result { () throws -> (URL, FixtureManifest) in
    let root = URL(fileURLWithPath: #filePath, isDirectory: false)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/discogs-tests", isDirectory: true)
    _ = try generateFixtures(count: coveringLibraryFileCount, in: root)
    return (root, try loadManifest(in: root))
}

enum WrittenSample: String, CaseIterable, CustomTestStringConvertible {
    case flac, mp4, mp3v23, mp3v24, aiff

    var testDescription: String { rawValue }

    func matches(_ file: FixtureFile) -> Bool {
        guard file.malformation == nil, file.tags != nil else { return false }
        switch self {
        case .flac: return file.container == .flac
        case .mp4: return file.container == .mp4
        case .mp3v23: return file.container == .mp3 && file.tagFormats == [.id3v23]
        case .mp3v24: return file.container == .mp3 && file.tagFormats == [.id3v24]
        case .aiff: return file.container == .aiff && file.tagFormats == [.id3v24]
        }
    }

    /// Two copies of one fixture in a new temp folder, which the test may write.
    func copies() throws -> [URL] {
        let (root, manifest) = try library.get()
        let file = try #require(manifest.files.first(where: matches), "no \(rawValue) fixture")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("discogs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = root.appendingPathComponent(file.path, isDirectory: false)
        return try (1...2).map { index in
            let copy = folder.appendingPathComponent(
                "\(index)-" + source.lastPathComponent, isDirectory: false)
            try FileManager.default.copyItem(at: source, to: copy)
            return copy
        }
    }
}

private let release = CatalogRelease(
    id: 2_201_998, masterID: 9, title: "Hey Hey",
    artists: [artist(51, "Benedek", join: ","), artist(52, "Tom Noble (2)", anv: "Tom")],
    labels: [label(61, "Leng", "LENG 012"), label(62, "Other (2)", "OTH 1")],
    formats: [format("CD", ["Album"])], country: "UK", released: "2010-09-00",
    genres: ["Folk, World, & Country"], styles: ["Celtic", "Folk"],
    credits: [
        CatalogCredit(id: 70, name: "Mia", role: "Mastered By"),
        CatalogCredit(id: 71, name: "Jo", role: "Producer"),
        CatalogCredit(id: 72, name: "Perälä", role: "Mixed By", tracks: "2"),
    ],
    tracks: [song("1", "Hey Hey"), song("2", "Ho Ho")])

/// The files as the window reads them, ids from 1 in order.
private func albumFiles(_ urls: [URL]) throws -> [AlbumFile] {
    let (files, problems) = readAlbumFiles(
        urls.enumerated().map { (id: Int64($0.offset + 1), path: $0.element.path) })
    try #require(problems == [])
    return files
}

@Test(arguments: WrittenSample.allCases, DiscogsPreset.all.map(\.name))
func aMappingsEditsWriteAndReadBackAsMeant(_ sample: WrittenSample, _ preset: String) throws {
    let mapping = try #require(DiscogsPreset.all.first { $0.name == preset }).mapping
    let urls = try sample.copies()
    let set = changeSet(for: try albumFiles(urls), match: match(release), mapping: mapping)
    #expect(!set.files.flatMap(\.changes).isEmpty)
    let writer = TagWriter(
        journal: TagUndoJournal(
            dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "discogs-journal-\(UUID().uuidString)", isDirectory: true)))
    // One batch, a different edit per file, as Apply writes a match set (ADR 0133).
    let report = writer.write(try set.edits())
    #expect(report.failures == [])
    #expect(report.changed == urls.map(\.path))
    let again = changeSet(for: try albumFiles(urls), match: match(release), mapping: mapping)
    #expect(again.files.flatMap(\.changes) == [])
}

@Test func aFileThatCantBeReadIsAProblemAndTheRestAreRead() throws {
    let urls = try WrittenSample.flac.copies()
    let missing = urls[0].deletingLastPathComponent().appendingPathComponent(
        "gone.flac", isDirectory: false)
    let read = Counted()
    let (files, problems) = readAlbumFiles(
        [(1, urls[0].path), (2, missing.path), (3, urls[1].path)], read: { read.set($0) })
    #expect(files.map(\.id) == [1, 3])
    #expect(problems.count == 1)
    #expect(problems.first?.contains("gone.flac") == true)
    #expect(read.value == 3)
}

/// The latest count a read reported, from its threads.
private final class Counted: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = 0

    func set(_ value: Int) { lock.withLock { latest = max(latest, value) } }
    var value: Int { lock.withLock { latest } }
}
