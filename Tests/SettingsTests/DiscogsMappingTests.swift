import Foundation
import Metadata
import TagWriter
import Testing

@testable import Settings

private let schema = AppSettings()

private func parsed(_ text: String) throws(ConfigErrorList) -> ConfigContents {
    try ConfigFile.parse(
        ConfigText(text), settings: schema.settings, check: { _, _, _ in nil },
        conflicts: schema.conflicts)
}

private func roundTripped(_ mapping: DiscogsMapping) throws -> DiscogsMapping {
    try JSONDecoder().decode(DiscogsMapping.self, from: JSONEncoder().encode(mapping))
}

/// The one-to-one mapping as JSON, with `change` made to it.
private func mappingJSON(_ change: (inout [String: Any]) -> Void) throws -> String {
    let data = try JSONEncoder().encode(DiscogsPreset.oneToOne.mapping)
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    change(&object)
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func mappingProblem(_ json: String) -> String? {
    do {
        _ = try parsed(#"{"discogs.mapping": \#(json)}"#)
        return nil
    } catch {
        return error.problems.map(\.description).joined(separator: "; ")
    }
}

@Test func thePresetsHaveNoProblemsAndRoundTripThroughJSON() throws {
    for preset in DiscogsPreset.all {
        #expect(preset.mapping.problem() == nil, "\(preset.name)")
        #expect(try roundTripped(preset.mapping) == preset.mapping, "\(preset.name)")
        #expect(Set(preset.mapping.rules.keys) == Set(DiscogsField.allCases), "\(preset.name)")
    }
    #expect(DiscogsPreset.all.map(\.name) == ["One to one", "Minimal", "Like my library"])
    // A preset's check is kept, and a change to its rules checks them again.
    var changed = DiscogsPreset.oneToOne.mapping
    changed[.album] = DiscogsFieldRule(.replace, [])
    #expect(changed.problem() == "album is on with no target")
    #expect(schema.discogsMapping.defaultValue == DiscogsPreset.oneToOne.mapping)
    #expect(schema.discogsSavedMappings.defaultValue == [])
}

@Test func oneToOneSendsEachFieldToATagOfItsOwnAndMinimalWritesFour() {
    let oneToOne = DiscogsPreset.oneToOne.mapping
    #expect(oneToOne.rules.values.allSatisfy { $0.mode == .replace && $0.targets.count == 1 })
    #expect(oneToOne[.genres].targets == [.field(.genre)])
    #expect(oneToOne[.styles].targets == [.key("STYLE")])
    #expect(oneToOne[.label].targets == [.field(.publisher)])
    let minimal = DiscogsPreset.minimal.mapping
    #expect(
        Set(minimal.rules.filter { $0.value.mode != .off }.keys)
            == [.releaseID, .label, .catalogNumber, .date])
    #expect(minimal[.date].format.date == .year)
}

@Test func likeMyLibrarySpellsKeysAsYATEDoesInEachFormat() {
    let mapping = DiscogsPreset.likeMyLibrary.mapping
    func tags(_ field: DiscogsField, _ format: TagFormat) -> [String] {
        mapping[field].targets.map { $0.tag(in: format).name }
    }
    #expect(tags(.releaseURL, .vorbis) == ["DISCOGS_RELEASE_URL"])
    #expect(tags(.releaseURL, .mp4) == ["DISCOGS_RELEASE_URL"])
    #expect(tags(.releaseURL, .id3) == ["WXXX:DISCOGS_RELEASE_URL"])
    #expect(tags(.involvedPeople, .id3) == ["TIPL"])
    #expect(tags(.ordinalPosition, .vorbis) == ["DISCOGS_RELEASE_ORDINAL_POSITION"])
    #expect(tags(.ordinalPosition, .mp4) == ["Discogs Release Ordinal Position"])
    #expect(tags(.position, .id3) == ["Track Number Text"])
    #expect(tags(.country, .vorbis) == ["DISCOGS_ALBUM_RELEASECOUNTRY", "COUNTRY"])
    #expect(tags(.country, .mp4) == ["Discogs Album Release Country", "Country"])
    #expect(tags(.label, .id3) == ["publisher", "grouping"])
    #expect(tags(.styles, .mp4) == ["mood"])
    #expect(mapping[.genres].format.template == "{genre} - {styles}")
    let numbers = mapping[.labelCatalogNumbers].targets[0]
    #expect(numbers.tag(in: .vorbis, value: 1) == .custom("DISCOGS CATALOG NUMBER-2"))
    #expect(numbers.tag(in: .mp4, value: 2) == .custom("DISCOGS_CATALOG_NUMBER-3"))
    #expect(
        mapping[.artistURL].targets[0].tag(in: .id3, value: 1)
            == .custom("WXXX:DISCOGS_ARTIST_URL-2"))
    #expect(mapping[.releaseURL].targets[0].tag(in: .id3, value: 1) == nil)
}

@Test func aTargetIsAStringUnlessItIsSpelledPerFormatOrNumbered() throws {
    let rule = DiscogsFieldRule(
        .fillEmpty,
        [
            .field(.genre), .key("STYLE"),
            .key(PerTagFormat(vorbis: "A", mp4: "B", id3: "B")),
            .key(PerTagFormat("URL"), numbered: PerTagFormat("URL")),
        ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let json = String(decoding: try encoder.encode(rule), as: UTF8.self)
    #expect(
        json
            == #"{"mode":"fillEmpty","to":["genre","STYLE",{"key":{"id3":"B","mp4":"B","vorbis":"A"}},{"key":"URL","numbered":"URL"}]}"#
    )
    #expect(try JSONDecoder().decode(DiscogsFieldRule.self, from: Data(json.utf8)) == rule)
}

@Test func theMappingSettingReadsFromTheConfigFile() throws {
    let json = try mappingJSON { object in
        object["styles"] = ["mode": "replace", "to": ["mood", "STYLE"], "format": ["join": "; "]]
    }
    let mapping =
        try parsed(#"{"discogs.mapping": \#(json)}"#).values["discogs.mapping"]
        as? DiscogsMapping
    #expect(
        mapping?[.styles]
            == DiscogsFieldRule(
                .replace, [.field(.mood), .key("STYLE")], format: DiscogsFieldFormat(join: "; ")))
}

@Test func aMappingThatCantBeFollowedIsAProblem() throws {
    let cases: [(String, (inout [String: Any]) -> Void)] = [
        ("no rule for styles", { $0["styles"] = nil }),
        ("isn't a Discogs field", { $0["mood"] = ["mode": "off", "to": []] }),
        ("unknown key", { $0["styles"] = ["mode": "replace", "to": ["STYLE"], "join": ","] }),
        ("needs a join", { $0["styles"] = ["mode": "replace", "to": ["STYLE"]] }),
        ("on with no target", { $0["album"] = ["mode": "replace", "to": []] }),
        (
            "isn't a field",
            {
                $0["genres"] = [
                    "mode": "replace", "to": ["genre"],
                    "format": ["join": ", ", "template": "{genre} - {style}"],
                ]
            }
        ),
        (
            "both write",
            { $0["styles"] = ["mode": "replace", "to": ["genre"], "format": ["join": ", "]] }
        ),
        (
            "both write",
            { $0["country"] = ["mode": "replace", "to": ["discogs_release_id"]] }
        ),
        (
            "doesn't hold",
            { $0["releaseURL"] = ["mode": "replace", "to": [ID3CustomKey.url("X")]] }
        ),
        ("printable ASCII", { $0["releaseURL"] = ["mode": "replace", "to": ["A=B"]] }),
        ("a field's name", { $0["releaseURL"] = ["mode": "replace", "to": ["LABEL"]] }),
        ("unknown key", { $0["album"] = ["mode": "replace", "to": [["key": "A", "kind": "x"]]] }),
    ]
    for (expected, change) in cases {
        let problem = mappingProblem(try mappingJSON(change))
        #expect(problem?.contains(expected) == true, "\(expected): \(problem ?? "none")")
    }
    // A field that's off may keep a target another field writes.
    let off = try mappingJSON {
        $0["styles"] = ["mode": "off", "to": ["genre"], "format": ["join": ", "]]
    }
    #expect(mappingProblem(off) == nil)
}

@Test func aSavedMappingNeedsANameThatIsntAPresets() throws {
    let mapping = String(
        decoding: try JSONEncoder().encode(DiscogsPreset.minimal.mapping), as: UTF8.self)
    let saved =
        try parsed(
            #"{"discogs.savedMappings": [{"name": "Mine", "mapping": \#(mapping)}]}"#
        ).values["discogs.savedMappings"] as? [NamedDiscogsMapping]
    #expect(saved == [NamedDiscogsMapping(name: "Mine", mapping: DiscogsPreset.minimal.mapping)])
    for (name, expected) in [("Minimal", "a preset's name"), (" ", "has no name")] {
        do {
            _ = try parsed(
                #"{"discogs.savedMappings": [{"name": "\#(name)", "mapping": \#(mapping)}]}"#)
            Issue.record("\(name) was accepted")
        } catch {
            #expect(error.problems.map(\.description).joined().contains(expected), "\(name)")
        }
    }
}
