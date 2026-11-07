import Foundation
import Testing

@testable import Metadata
@testable import TagWriter

// Custom keys set, replaced, removed and undone in each format the writer handles, each in the
// key ADR 0129 names (spelled out here apart from the code).

private let customSamples: [Sample] = [
    .flac, .flacWithArt, .mp4, .mp3v23, .mp3v24, .mp3Untagged, .aiffV23, .wavID3, .wavInfoOnly,
]

/// Where a custom key named `name` sits in a file's layout.
private func customKeyPath(_ name: String, _ sample: Sample) -> String {
    switch sample {
    case .flac, .flacWithArt: "vorbisComment/" + name
    case .mp4: "moov/udta/meta/ilst/----:com.apple.iTunes:" + name
    case .aiffV23: "ID3 /TXXX"
    case .wavID3, .wavInfoOnly: "id3 /TXXX"
    default: "ID3/TXXX"
    }
}

@Test(arguments: customSamples)
func aCustomKeyIsSetReplacedRemovedAndUndone(_ sample: Sample) throws {
    let url = try sample.copy()
    let pristine = try scratchCopy(of: url)
    let original = try Data(contentsOf: url)
    let originalTags = try tags(url)
    let writer = scratchWriter()

    let set = TagEdit(
        values: [.title: "Titled"],
        custom: ["DISCOGS_RELEASE_ID": "1234567", "discogs_master_id": "m744074"])
    expectChanged(writer.write(set, to: [url.path]), [url])
    let written = try tags(url)
    #expect(written == (try set.applied(to: originalTags)))
    #expect(written.custom["DISCOGS_RELEASE_ID"] == "1234567")
    #expect(written.custom["DISCOGS_MASTER_ID"] == "m744074")
    #expect(written.title == "Titled")
    let layout = try readTagLayout(at: url)
    for name in ["DISCOGS_RELEASE_ID", "DISCOGS_MASTER_ID"] {
        #expect(
            layout.blocks.contains {
                $0.path == customKeyPath(name, sample) && $0.customKey == name
            }, "\(name): \(layout.blocks.map(\.path))")
    }
    #expect(try untouchedBlockDifferences(original: pristine, edited: url, edit: set) == [])

    let replaced = TagEdit(custom: ["Discogs_Release_ID": "7654321"])
    expectChanged(writer.write(replaced, to: [url.path]), [url])
    #expect(try tags(url).custom["DISCOGS_RELEASE_ID"] == "7654321")
    #expect(try tags(url).custom["DISCOGS_MASTER_ID"] == "m744074")
    #expect(
        try readTagLayout(at: url).blocks.filter { $0.customKey == "DISCOGS_RELEASE_ID" }.count
            == 1)

    let removed = TagEdit(custom: ["DISCOGS_RELEASE_ID": "", "DISCOGS_MASTER_ID": ""])
    expectChanged(writer.write(removed, to: [url.path]), [url])
    #expect(
        try tags(url)
            == (try set.applied(to: originalTags)).with { $0.custom = originalTags.custom })
    #expect(
        try readTagLayout(at: url).blocks.allSatisfy { $0.customKey?.hasPrefix("DISCOGS") != true })

    for _ in 0..<3 { expectChanged(writer.undoLast(), [url]) }
    #expect(try Data(contentsOf: url) == original)
}

@Test func anEditOfACustomKeyTheFileAlreadyHoldsAsWrittenChangesNothing() throws {
    let url = try Sample.flac.copy()
    let writer = scratchWriter()
    let edit = TagEdit(custom: ["DISCOGS_RELEASE_ID": "1"])
    expectChanged(writer.write(edit, to: [url.path]), [url])
    let report = writer.write(TagEdit(custom: ["discogs_release_id": "1"]), to: [url.path])
    #expect(report.changed.isEmpty)
    #expect(report.failures.isEmpty)
}

@Test func aCustomKeyMustBeNamedSoEveryFormatHoldsItAndNoFieldReadsIt() {
    for name in ["", "A=B", "Perälä", "TAB\tKEY"] {
        #expect(throws: TagValueError.self, "\(name)") {
            try TagEdit(custom: [name: "x"]).applied(to: TrackTags())
        }
    }
    for name in ["LABEL", "catalognumber", "ITUNSMPB", "Album Artist"] {
        #expect(throws: TagValueError.self, "\(name)") {
            try TagEdit(custom: [name: "x"]).applied(to: TrackTags())
        }
    }
    #expect(throws: TagValueError.self) {
        try TagEdit(custom: ["DISCOGS_RELEASE_ID": "1\u{0}2"]).applied(to: TrackTags())
    }
    let error = TagValueError(field: nil, text: "x", detail: "is bad", customKey: "KEY")
    #expect(error.description == "KEY \"x\" is bad")
    #expect(TagEdit(custom: ["A": ""]).isEmpty == false)
}

extension TrackTags {
    fileprivate func with(_ change: (inout TrackTags) -> Void) -> TrackTags {
        var copy = self
        change(&copy)
        return copy
    }
}
