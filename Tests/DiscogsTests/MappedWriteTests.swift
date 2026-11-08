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

private func albumFiles(_ urls: [URL]) throws -> [AlbumFile] {
    try urls.enumerated().map { index, url in
        AlbumFile(
            id: Int64(index + 1), path: url.path, metadata: try readMetadata(at: url).metadata)
    }
}

@Test(arguments: WrittenSample.allCases, DiscogsPreset.all.map(\.name))
func aMappingsEditsWriteAndReadBackAsMeant(_ sample: WrittenSample, _ preset: String) throws {
    let mapping = try #require(DiscogsPreset.all.first { $0.name == preset }).mapping
    let urls = try sample.copies()
    let set = changeSet(for: try albumFiles(urls), match: match(release), mapping: mapping)
    #expect(set.changeCount > 0)
    let writer = TagWriter(
        journal: TagUndoJournal(
            dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "discogs-journal-\(UUID().uuidString)", isDirectory: true)))
    for (path, edit) in try set.edits() {
        let report = writer.write(edit, to: [path])
        #expect(report.failures == [], "\(path)")
        #expect(report.changed == [path])
    }
    let again = changeSet(for: try albumFiles(urls), match: match(release), mapping: mapping)
    #expect(again.files.flatMap(\.changes) == [])
}
