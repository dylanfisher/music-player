import Foundation
import Testing

@testable import Settings
@testable import SettingsWindow

/// A model over a dictionary standing in for the config file, holding `mapping`, and the
/// dictionary.
@MainActor
private func model(_ mapping: DiscogsMapping = DiscogsPreset.oneToOne.mapping)
    -> (TaggingModel, () -> [String: Any])
{
    nonisolated(unsafe) var values: [String: Any] = [TaggingModel.setting.key: json(mapping)]
    let model = TaggingModel(
        value: { values[$0] }, set: { key, json in values[key] = json }, isBlocked: { false })
    return (model, { values })
}

/// `mapping` as JSON holds it.
private func json(_ mapping: DiscogsMapping) -> Any {
    try! JSONSerialization.jsonObject(
        with: Data(TaggingModel.setting.text(mapping).utf8), options: .fragmentsAllowed)
}

/// The mapping the JSON holds, read as the config file reads it.
private func mapping(_ json: Any?) throws -> DiscogsMapping {
    let data = try JSONSerialization.data(withJSONObject: try #require(json))
    return try TaggingModel.setting.value(fromText: String(decoding: data, as: UTF8.self))
}

@MainActor @Test func aFormatPartIsSavedAsTheMappingInUse() throws {
    let (model, values) = model()
    #expect(!model.isEdited)
    #expect(!model.canSave)
    let suffixes = TaggingModel.Part.suffixes
    #expect(model.draft[.artist].format.suffixes == nil)
    #expect(suffixes.selected(in: model.draft[.artist].format) == 0, "left out, it keeps them")
    model.choose(1, of: suffixes, for: .artist)
    #expect(model.draft[.artist].format.suffixes == .drop)
    #expect(model.ruleText(.artist) == "Replace Tag · artist · Drop “(2)”")
    #expect(model.canSave)
    try model.save()
    #expect(!model.isEdited)
    let saved = try mapping(values()[TaggingModel.setting.key])
    #expect(saved[.artist].format.suffixes == .drop)
    #expect(saved == model.draft)
}

@MainActor @Test func aPartLeftOutShowsWhatItWrites() throws {
    let (model, _) = model()
    let format = model.draft[.label].format
    #expect(format.repeats == nil)
    // Repeats left out drop them, so choosing Once changes nothing.
    #expect(
        TaggingModel.Part.repeats.choices[TaggingModel.Part.repeats.selected(in: format)] == "Once")
    model.choose(1, of: .repeats, for: .label)
    #expect(!model.isEdited)
    model.choose(0, of: .repeats, for: .label)
    #expect(model.draft[.label].format.repeats == .keep)
    model.choose(1, of: .credits(.mp4), for: .involvedPeople)
    #expect(
        model.draft[.involvedPeople].format.credits
            == PerTagFormat(vorbis: .nameRole, mp4: .roleNames, id3: .nameRole))
    #expect(
        model.ruleText(.involvedPeople).hasSuffix(
            "credits Name (Role) / Role;;;Name,Name / Name (Role)"))
}

@MainActor @Test func theProblemIsTheConfigFilesAndBlocksSave() throws {
    let (model, values) = model()
    model.draft[.genres].setJoin("")
    let expected: String
    do {
        _ = try TaggingModel.setting.value(fromText: TaggingModel.setting.text(model.draft))
        Issue.record("the config file took a list with no join")
        return
    } catch {
        expected = "\(error)"
    }
    #expect(model.problem == expected)
    #expect(expected.contains("genres is a list, so it needs a join"), "\(expected)")
    #expect(!model.canSave)
    #expect(throws: ConfigProblem.self) { try model.save() }
    #expect(try mapping(values()[TaggingModel.setting.key]) == DiscogsPreset.oneToOne.mapping)
    model.revert()
    #expect(!model.isEdited)
    #expect(model.problem == nil)
}

@MainActor @Test func tagsAreAddedSpelledPerFormatNumberedAndRemoved() throws {
    let (model, _) = model()
    let position = model.addTag(for: .country)
    #expect(model.problem?.contains("isn't a custom key's name") == true)
    model.setTag("RELEASECOUNTRY", in: .vorbis, at: position, for: .country)
    #expect(model.tags(.country)[position] == .key("RELEASECOUNTRY"))
    #expect(model.problem == nil)
    model.setTag("Release Country", in: .mp4, at: position, for: .country)
    model.setTag("Release Country", in: .id3, at: position, for: .country)
    #expect(
        model.tags(.country)[position]
            == .key(
                PerTagFormat(
                    vorbis: "RELEASECOUNTRY", mp4: "Release Country", id3: "Release Country")))
    #expect(
        model.tags(.country)[position].text
            == "RELEASECOUNTRY / Release Country / Release Country")
    // Spelled per format, a vorbis name changes vorbis alone.
    model.setTag("COUNTRY_OF_RELEASE", in: .vorbis, at: position, for: .country)
    #expect(model.tags(.country)[position].names.mp4 == "Release Country")
    // A field's name is that field, as the config file reads it.
    model.setTag("genre", in: .vorbis, at: 0, for: .styles)
    #expect(model.tags(.styles) == [.field(.genre)])
    model.setNumbered(true, at: 0, for: .labelURL)
    #expect(model.tags(.labelURL)[0].isNumbered)
    let numbered = model.tags(.labelURL)[0].numberedNames
    model.setTag("LABEL_LINK", in: .vorbis, at: 0, for: .labelURL)
    #expect(model.tags(.labelURL)[0].numberedNames == PerTagFormat("LABEL_LINK"))
    #expect(numbered != PerTagFormat("LABEL_LINK"))
    model.setNumbered(false, at: 0, for: .labelURL)
    #expect(!model.tags(.labelURL)[0].isNumbered)
    model.removeTag(at: position, for: .country)
    #expect(model.tags(.country).count == position)
}

@MainActor @Test func aNumberedKeySpelledOtherwiseKeepsItsSpelling() throws {
    let (model, _) = model(DiscogsPreset.yate.mapping)
    let target = model.tags(.labelCatalogNumbers)[0]
    #expect(target.numberedNames != target.names)
    model.setTag("CATNO", in: .vorbis, at: 0, for: .labelCatalogNumbers)
    #expect(model.tags(.labelCatalogNumbers)[0].numberedNames == target.numberedNames)
}

@MainActor @Test func aReloadTakesTheFilesMappingUnlessTheDraftIsEdited() throws {
    nonisolated(unsafe) var values: [String: Any] = [
        TaggingModel.setting.key: json(DiscogsPreset.oneToOne.mapping)
    ]
    let model = TaggingModel(
        value: { values[$0] }, set: { key, json in values[key] = json }, isBlocked: { false })
    values[TaggingModel.setting.key] = json(DiscogsPreset.yate.mapping)
    model.reload()
    #expect(model.draft == DiscogsPreset.yate.mapping)
    #expect(!model.isEdited)
    #expect(model.note == nil)
    model.draft[.barcode].mode = .off
    values[TaggingModel.setting.key] = json(DiscogsPreset.minimal.mapping)
    model.reload()
    #expect(model.draft[.barcode].mode == .off)
    #expect(model.draft[.album] == DiscogsPreset.yate.mapping[.album])
    #expect(model.note == TaggingModel.changedNote)
    model.revert()
    #expect(model.draft == DiscogsPreset.minimal.mapping)
    #expect(model.note == nil)
}

@MainActor @Test func aBlockedFileCantBeSavedTo() throws {
    let model = TaggingModel(
        value: { _ in json(DiscogsPreset.oneToOne.mapping) }, set: { _, _ in },
        isBlocked: { true })
    model.draft[.barcode].mode = .off
    #expect(model.problem == nil)
    #expect(!model.canSave)
}

// MARK: Over the config file

/// Made up for these tests; no real token appears in a test (ADR 0137, ADR 0144).
private let discogsToken = "fakeTOKENfor3tests0nly"
private let serviceToken = "fake-service-token-for-tests-0nly"

/// A config file at mode 0600 in a fresh temporary folder, holding both secrets around the
/// mapping, each line of its own; the text before the mapping's value, and after it.
private func secretsFile() throws -> (URL, before: String, after: String) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tagging-\(UUID().uuidString)/config.json")
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let before = """
        {
          // The Discogs token.
          "discogs.token": "\(discogsToken)",
          "discogs.mapping":
        """
    let after = """
        ,
          "recommender.token":   "\(serviceToken)" ,
          "library.groupByAlbumArtist": false
        }

        """
    let mapping = TaggingModel.setting.text(DiscogsPreset.oneToOne.mapping)
        .trimmingCharacters(in: .newlines)
    try Data((before + mapping + after).utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return (url, before, after)
}

@MainActor
private func store(_ url: URL) -> ConfigStore<AppSettings> {
    ConfigStore(AppSettings(), fileURL: url, check: { _, _, _ in nil }, creating: false)
}

/// A model over `settings`, wired as the app wires the Settings window's.
@MainActor
private func model(over settings: ConfigStore<AppSettings>) -> TaggingModel {
    TaggingModel(
        value: { settings.json(forKey: $0) },
        set: { key, json in try settings.set(key: key, json: json) },
        isBlocked: { settings.blocked })
}

@MainActor @Test func aSaveLeavesBothSecretsByteForByteAtMode0600() throws {
    let (url, before, after) = try secretsFile()
    let settings = store(url)
    #expect(settings.problems.isEmpty, "\(settings.problems)")
    let model = model(over: settings)
    model.choose(1, of: .suffixes, for: .albumArtist)
    model.setTag("ALBUM_ARTIST_LINK", in: .vorbis, at: 0, for: .albumArtistURL)
    try model.save()
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.hasPrefix(before), "\(text)")
    #expect(text.hasSuffix(after), "\(text)")
    #expect(text.contains("\"suffixes\" : \"drop\"") || text.contains("\"suffixes\": \"drop\""))
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
    #expect(mode as? Int == 0o600)
    #expect(settings[\.discogsToken] == DiscogsToken(discogsToken))
    #expect(settings[\.recommenderToken]?.secret == serviceToken)
    #expect(settings[\.discogsMapping][.albumArtist].format.suffixes == .drop)
}

@MainActor @Test func anEditInTheFileShowsInThePane() throws {
    let (url, _, _) = try secretsFile()
    let settings = store(url)
    let model = model(over: settings)
    settings.changed = { _ in model.reload() }
    var text = try String(contentsOf: url, encoding: .utf8)
    let edited = TaggingModel.setting.text(DiscogsPreset.yate.mapping)
        .trimmingCharacters(in: .newlines)
    let oneToOne = TaggingModel.setting.text(DiscogsPreset.oneToOne.mapping)
        .trimmingCharacters(in: .newlines)
    text = text.replacingOccurrences(of: oneToOne, with: edited)
    try Data(text.utf8).write(to: url)
    settings.read(confirmed: false)
    #expect(model.draft == DiscogsPreset.yate.mapping)
    #expect(!model.isEdited)
}
