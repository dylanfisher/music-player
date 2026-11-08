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
        custom: ["DISCOGS_RELEASE_ID": "1234567", "DISCOGS_MASTER_ID": "m744074"])
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

    let replaced = TagEdit(custom: ["DISCOGS_RELEASE_ID": "7654321"])
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

@Test(arguments: [Sample.flac, .mp4, .mp3v24])
func aCustomKeyIsWrittenAsSpelledAndReplacesItsNameInAnyCase(_ sample: Sample) throws {
    let url = try sample.copy()
    let writer = scratchWriter()
    let name = "Discogs Release Notes"
    expectChanged(writer.write(TagEdit(custom: [name: "First"]), to: [url.path]), [url])
    let spelled = try Data(contentsOf: url)
    #expect(spelled.range(of: Data(name.utf8)) != nil, "written as spelled")
    expectChanged(
        writer.write(TagEdit(custom: ["DISCOGS RELEASE NOTES": "Second"]), to: [url.path]), [url])
    #expect(try tags(url).custom["DISCOGS RELEASE NOTES"] == "Second")
    let layout = try readTagLayout(at: url)
    #expect(layout.blocks.filter { $0.customKey == "DISCOGS RELEASE NOTES" }.count == 1)
    #expect(try Data(contentsOf: url).range(of: Data(name.utf8)) == nil, "the old spelling went")
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
    #expect(throws: TagValueError.self) {
        try TagEdit(custom: ["KEY": "x", "key": "y"]).applied(to: TrackTags())
    }
    #expect(TagEdit(custom: ["A": ""]).isEmpty == false)
}

extension TrackTags {
    fileprivate func with(_ change: (inout TrackTags) -> Void) -> TrackTags {
        var copy = self
        change(&copy)
        return copy
    }
}

private let id3Samples: [Sample] = [.mp3v23, .mp3v24, .mp3Untagged, .aiffV23, .wavID3]

/// Where an ID3 frame of `id` sits in a file's layout.
private func id3FramePath(_ id: String, _ sample: Sample) -> String {
    switch sample {
    case .aiffV23: "ID3 /" + id
    case .wavID3, .wavInfoOnly: "id3 /" + id
    default: "ID3/" + id
    }
}

@Test(arguments: id3Samples)
func aLinkAndTheInvolvedPeopleListAreSetReplacedRemovedAndUndoneInID3(_ sample: Sample) throws {
    let url = try sample.copy()
    let original = try Data(contentsOf: url)
    let originalTags = try tags(url)
    let writer = scratchWriter()
    let link = ID3CustomKey.url("DISCOGS_RELEASE_URL")
    let people = ID3CustomKey.involvedPeople

    let set = TagEdit(
        custom: [
            link: "https://www.discogs.com/release/1234567", people: "Producer;;;Perälä, B",
            "DISCOGS_RELEASE_URL": "a TXXX of the same description",
        ])
    expectChanged(writer.write(set, to: [url.path]), [url])
    let written = try tags(url)
    #expect(written == (try set.applied(to: originalTags)))
    #expect(written.custom["WXXX:DISCOGS_RELEASE_URL"] == "https://www.discogs.com/release/1234567")
    #expect(written.custom["TIPL"] == "Producer;;;Perälä, B")
    #expect(written.custom["DISCOGS_RELEASE_URL"] == "a TXXX of the same description")
    let version3 = [Sample.mp3v23, .aiffV23, .wavID3].contains(sample)
    let layout = try readTagLayout(at: url)
    #expect(
        layout.blocks.contains {
            $0.path == id3FramePath("WXXX", sample) && $0.customKey == "WXXX:DISCOGS_RELEASE_URL"
        }, "\(layout.blocks.map(\.path))")
    #expect(
        layout.blocks.contains {
            $0.path == id3FramePath(version3 ? "IPLS" : "TIPL", sample) && $0.customKey == "TIPL"
        }, "\(layout.blocks.map(\.path))")

    let replaced = TagEdit(custom: [
        "wxxx:discogs_release_url": "https://www.discogs.com/release/7", people: "Mixed By;;;C",
    ])
    expectChanged(writer.write(replaced, to: [url.path]), [url])
    #expect(try tags(url).custom["WXXX:DISCOGS_RELEASE_URL"] == "https://www.discogs.com/release/7")
    #expect(try tags(url).custom["TIPL"] == "Mixed By;;;C")
    #expect(try tags(url).custom["DISCOGS_RELEASE_URL"] == "a TXXX of the same description")
    #expect(
        try readTagLayout(at: url).blocks.filter { $0.customKey == "WXXX:DISCOGS_RELEASE_URL" }
            .count == 1)

    let removed = TagEdit(custom: [link: "", people: "", "DISCOGS_RELEASE_URL": ""])
    expectChanged(writer.write(removed, to: [url.path]), [url])
    #expect(try tags(url).custom == originalTags.custom)

    for _ in 0..<3 { expectChanged(writer.undoLast(), [url]) }
    #expect(try Data(contentsOf: url) == original)
}

@Test func anInvolvedPeopleListOutOfPairsOrALinkOutsideLatin1IsRefused() throws {
    let url = try Sample.mp3v24.copy()
    let original = try Data(contentsOf: url)
    let writer = scratchWriter()
    for edit in [
        TagEdit(custom: [ID3CustomKey.involvedPeople: "Producer;;;A;;;Mixed By"]),
        TagEdit(custom: [ID3CustomKey.url("LINK"): "https://example.com/Perälä→"]),
    ] {
        let report = writer.write(edit, to: [url.path])
        #expect(report.changed.isEmpty)
        #expect(report.failures.count == 1)
    }
    #expect(try Data(contentsOf: url) == original)
}

@Test(arguments: [Sample.flac, .mp4])
func id3OnlyKeysAreRefusedInFormatsWithoutThem(_ sample: Sample) throws {
    let url = try sample.copy()
    let original = try Data(contentsOf: url)
    let writer = scratchWriter()
    for name in [ID3CustomKey.url("DISCOGS_RELEASE_URL"), ID3CustomKey.involvedPeople] {
        let report = writer.write(TagEdit(custom: [name: "x;;;y"]), to: [url.path])
        #expect(report.changed.isEmpty)
        #expect(report.failures.map(\.detail).first?.contains("is an ID3 frame") == true)
    }
    #expect(try Data(contentsOf: url) == original)
}
