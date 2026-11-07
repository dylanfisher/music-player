import Foundation
import Testing

@testable import TagCorpus

/// A FLAC file of 4,410 frames at 44.1 kHz holding `comments`, with a few bytes standing in for
/// its audio.
private func flac(_ comments: [String]) -> Data {
    func littleEndian(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
    let packed = UInt64(44_100) << 44 | UInt64(1) << 41 | UInt64(15) << 36 | 4410
    let streamInfo: [UInt8] =
        [0x10, 0x00, 0x10, 0x00] + [UInt8](repeating: 0, count: 6)
        + (0..<8).reversed().map { UInt8(packed >> (8 * UInt64($0)) & 0xFF) }
        + [UInt8](repeating: 0, count: 16)
    var vorbis = littleEndian(6) + Array("vendor".utf8) + littleEndian(comments.count)
    for comment in comments { vorbis += littleEndian(comment.utf8.count) + Array(comment.utf8) }
    var file = Array("fLaC".utf8)
    for (type, body) in [(UInt8(0), streamInfo), (0x84, vorbis)] {
        file += [
            type, UInt8(body.count >> 16), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF),
        ]
        file += body
    }
    return Data(file + [0xFF, 0xF8, 0x69, 0x08, 0x00, 0x00])
}

private func record(
    _ path: String, album: String = "Album", releaseID: String?, genre: String? = nil,
    mood: String? = nil, grouping: String? = nil, label: String? = nil, artist: String = "Artist"
) -> SurveyRecord {
    var record = SurveyRecord(path: path, failure: "")
    record.failure = nil
    record.format = "flac"
    record.album = album
    record.artist = artist
    record.genre = genre
    record.mood = mood
    record.grouping = grouping
    record.label = label
    if let releaseID { record.custom["DISCOGS_RELEASE_ID"] = releaseID }
    return record
}

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("discogs-survey-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // The walk lists the temp folder by its real path, /private/var rather than /var.
    return URL(fileURLWithPath: try resolvedPath(folder.path), isDirectory: true)
}

@Test func albumsAreCountedByHowManyTracksCarryOneReleaseID() {
    let records = [
        record("/m/a/1.flac", album: "One", releaseID: "1"),
        record("/m/a/2.flac", album: "One", releaseID: "1"),
        record("/m/b/1.flac", album: "Mixed", releaseID: "1"),
        record("/m/b/2.flac", album: "Mixed", releaseID: "2"),
        record("/m/c/1.flac", album: "Partial", releaseID: "3"),
        record("/m/c/2.flac", album: "Partial", releaseID: nil),
        record("/m/d/1.flac", album: "None", releaseID: nil),
    ]
    let report = surveyReport(records, folders: [URL(fileURLWithPath: "/m", isDirectory: true)])
    #expect(
        report.contains(
            "all formats: 4 albums; every track, one id 1, every track, several ids 1,"
                + " some tracks 1, no track 1"))
    #expect(
        report.contains("DISCOGS_RELEASE_ID: 5 files, 3 albums, 1 constant; \"1\" | \"2\" | \"3\""))
}

@Test func theOwnersGenreMoodAndGroupingLayoutIsRecognized() {
    let records = [
        record(
            "/m/a/1.flac", releaseID: "1", genre: "Electronic - Ambient, Dub Techno",
            mood: "Ambient, Dub Techno", grouping: "Label", label: "Label"),
        record(
            "/m/a/2.flac", releaseID: "1",
            genre: "Electronic - Ambient, Dub Techno - Ambient, Dub Techno",
            mood: "Ambient, Dub Techno", grouping: "Other", label: "Label", artist: "Name (2)"),
    ]
    let report = surveyReport(records, folders: [])
    #expect(report.contains("GENRE as \"genre - styles\": 2 of 2"))
    #expect(report.contains("  of those, the styles repeated after another \" - \": 1 of 2"))
    #expect(report.contains("MOOD equal to GENRE's styles: 2 of 2"))
    #expect(report.contains("GROUPING equal to LABEL: 1 of 2"))
    #expect(report.contains("ARTIST or ALBUMARTIST with a \"(2)\" suffix: 1 of 2; \"Name (2)\""))
}

@Test func genreLayoutSplitsTheGenreFromItsStylesAndFindsThemRepeated() {
    let layout = GenreLayout("Folk, World, & Country - Ambient, Dub Techno - Ambient, Dub Techno")
    #expect(layout?.genre == "Folk, World, & Country")
    #expect(layout?.styles == "Ambient, Dub Techno")
    #expect(layout?.isRepeated == true)
    #expect(GenreLayout("Electronic - Ambient")?.isRepeated == false)
    #expect(GenreLayout("Electronic, Rock") == nil)
    #expect(hasNumberSuffix("Name (2)"))
    #expect(!hasNumberSuffix("Name(2)"))
    #expect(!hasNumberSuffix("Name (Live)"))
}

@Test func theSurveyReadsEachFileOnceResumesAndLeavesTheFolderAsItWas() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let music = root.appendingPathComponent("music/Artist/Album", isDirectory: true)
    try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
    let first = music.appendingPathComponent("01.flac", isDirectory: false)
    let second = music.appendingPathComponent("02.flac", isDirectory: false)
    try flac(["ALBUM=Album", "DISCOGS_RELEASE_ID=42", "DISCOGS_MASTER_ID=m7"]).write(to: first)
    try flac(["ALBUM=Album", "DISCOGS_RELEASE_ID=42"]).write(to: second)
    try Data("not audio".utf8).write(to: music.appendingPathComponent("cover.jpg"))
    let before = try FileManager.default.attributesOfItem(atPath: first.path)
    let output = root.appendingPathComponent("survey", isDirectory: true)
    let lines = output.appendingPathComponent("files.jsonl", isDirectory: false)

    let folders = [root.appendingPathComponent("music", isDirectory: true)]
    #expect(try discogsSurvey(folders, output: output) == 0)
    let records = try loadRecords(lines)
    #expect(records.map(\.path) == [first.path, second.path])
    #expect(records[0].custom == ["DISCOGS_RELEASE_ID": "42", "DISCOGS_MASTER_ID": "m7"])
    let report = try String(
        contentsOf: output.appendingPathComponent("report.txt", isDirectory: false),
        encoding: .utf8)
    #expect(report.contains("every track, one id 1"))
    let after = try FileManager.default.attributesOfItem(atPath: first.path)
    #expect(after[.modificationDate] as? Date == before[.modificationDate] as? Date)

    // A stop partway through a line: the line is dropped, and the file it was for read again.
    let whole = try Data(contentsOf: lines)
    let firstLine = whole.prefix(through: whole.firstIndex(of: UInt8(ascii: "\n"))!)
    try (firstLine + Data("{\"path\":".utf8)).write(to: lines)
    #expect(try discogsSurvey(folders, output: output) == 0)
    #expect(try loadRecords(lines).map(\.path) == [first.path, second.path])
    #expect(try Data(contentsOf: lines) == whole)
}

@Test func theSurveyRefusesAFolderThatIsntThere() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appendingPathComponent("missing", isDirectory: true)
    #expect(throws: CorpusError.self) {
        try discogsSurvey([missing], output: root.appendingPathComponent("survey"))
    }
}

@Test func theSurveyFlagNeedsAFolderAndGoesFirst() {
    #expect(argumentProblem([discogsSurveyFlag, "/m"]) == nil)
    #expect(argumentProblem([discogsSurveyFlag, "/m", "/n"]) == nil)
    #expect(argumentProblem([discogsSurveyFlag]) != nil)
    #expect(argumentProblem(["/m", discogsSurveyFlag]) != nil)
}
