import Foundation
import Testing

@testable import Fixtures
@testable import Metadata
@testable import TagWriter

/// A fixture library of this target's own, since test targets run in one process and would
/// otherwise generate into the same directory at once.
let fixtureLibrary = Result { () throws -> (URL, FixtureManifest) in
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/tagwriter-tests")
    _ = try generateFixtures(count: coveringLibraryFileCount, in: root)
    return (root, try loadManifest(in: root))
}

/// The kinds of file the writer is tested on, each picked from the fixture library.
enum Sample: String, CaseIterable, CustomTestStringConvertible {
    case flac, flacWithArt, mp4, mp4WithArt, mp3v23, mp3v23WithArt, mp3v24, mp3v24WithArt
    case mp3Untagged, aiffV23, aiffV24, aiffWithArt, wavID3, wavInfoAndID3, wavInfoOnly

    var testDescription: String { rawValue }

    private var match: (FixtureFile) -> Bool {
        switch self {
        case .flac: { $0.container == .flac && $0.art == nil }
        case .flacWithArt: { $0.container == .flac && $0.art != nil }
        case .mp4: { $0.container == .mp4 && $0.art == nil }
        case .mp4WithArt: { $0.container == .mp4 && $0.art != nil }
        case .mp3v23: { $0.tagFormats == [.id3v23] && $0.container == .mp3 && $0.art == nil }
        case .mp3v23WithArt: { $0.tagFormats == [.id3v23] && $0.container == .mp3 && $0.art != nil }
        case .mp3v24: { $0.tagFormats == [.id3v24] && $0.container == .mp3 && $0.art == nil }
        case .mp3v24WithArt: { $0.tagFormats == [.id3v24] && $0.container == .mp3 && $0.art != nil }
        case .mp3Untagged: { $0.container == .mp3 && $0.tagFormats.isEmpty }
        case .aiffV23: { $0.container == .aiff && $0.tagFormats == [.id3v23] && $0.art == nil }
        case .aiffV24: { $0.container == .aiff && $0.tagFormats == [.id3v24] }
        case .aiffWithArt: { $0.container == .aiff && $0.art != nil }
        case .wavID3: { $0.container == .wav && $0.tagFormats == [.id3v23] }
        case .wavInfoAndID3: { $0.container == .wav && $0.tagFormats == [.riffInfo, .id3v24] }
        case .wavInfoOnly: { $0.container == .wav && $0.tagFormats == [.riffInfo] }
        }
    }

    /// A copy in a fresh temp folder, which the test may write.
    func copy() throws -> URL {
        let (root, manifest) = try fixtureLibrary.get()
        guard
            let file = manifest.files.first(where: {
                $0.malformation == nil && (self == .mp3Untagged || $0.tags != nil) && match($0)
            })
        else { throw SampleMissing(sample: self) }
        return try scratchCopy(of: root.appendingPathComponent(file.path))
    }
}

struct SampleMissing: Error { var sample: Sample }

/// `file` copied into a new folder under the temp directory.
func scratchCopy(of file: URL) throws -> URL {
    let folder = scratchFolder()
    let copy = folder.appendingPathComponent(file.lastPathComponent)
    try FileManager.default.copyItem(at: file, to: copy)
    return copy
}

func scratchFolder() -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("tagwriter-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A writer whose journal is in a folder of its own.
func scratchWriter() -> TagWriter {
    TagWriter(journal: TagUndoJournal(dataDirectory: scratchFolder()))
}

func tags(_ url: URL) throws -> TrackTags { try readMetadata(at: url).metadata.tags }

func art(_ url: URL) throws -> Data? {
    let parsed = try readMetadata(at: url)
    return try parsed.metadata.art.map { try readArt($0, at: url) }
}

/// A PNG of `side` pixels square, whose bytes vary so it doesn't compress away.
func pngImage(side: Int) -> Data {
    let header: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    var bytes = header
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    for _ in 0..<(side * side) {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        bytes.append(UInt8(truncatingIfNeeded: state >> 33))
    }
    return Data(bytes)
}

/// Fails unless `report` changed exactly `paths`.
func expectChanged(
    _ report: TagWriteReport, _ paths: [URL], sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(report.failures == [], sourceLocation: sourceLocation)
    #expect(report.changed == paths.map(\.path), sourceLocation: sourceLocation)
}
