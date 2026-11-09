import Foundation
import Testing

@testable import Settings

private let schema = AppSettings()
private let discogsToken = "fakeDISCOGSfor3secrets0nly"
private let serviceToken = "fake-service-token-for-secrets-tests"

/// The values `text` sets, as the app reads them.
private func values(_ text: String) throws -> [String: any SettingValue] {
    try ConfigFile.parse(
        ConfigText(text), settings: schema.settings, check: { _, _, _ in nil },
        conflicts: schema.conflicts
    ).values
}

@Test func theSecretsAreTheSchemasSecretSettings() {
    #expect(ConfigSecrets.keys == [schema.discogsToken.key, schema.recommenderToken.key].sorted())
}

@Test func removingTheSecretsKeepsEveryOtherSetting() throws {
    let text = """
        \u{FEFF}{
          // Takes text. Was "\(serviceToken)".
          "recommender.token": "\(serviceToken)", // \(discogsToken)
          "playback.playedPercent":
            50,
          "discogs.token": null,
          "library.groupByAlbumArtist": false,
        }
        """
    let removed = try ConfigSecrets.removed(from: text)
    #expect(!removed.contains(serviceToken))
    #expect(!removed.contains(discogsToken))
    #expect(!removed.contains("token"))
    #expect(!removed.contains("//"))
    let kept = try values(removed)
    #expect(kept["library.groupByAlbumArtist"] as? Bool == false)
    #expect(kept["playback.playedPercent"] as? Int == 50)
    #expect(kept.keys.allSatisfy { !ConfigSecrets.keys.contains($0) })
    // Taking them out twice changes nothing more.
    #expect(try ConfigSecrets.removed(from: removed) == removed)
}

@Test func textThatIsntAJSONObjectHasNothingRemoved() {
    for text in ["{ \"discogs.token\": \"\(discogsToken)\" ", "[]", "", "/* {} "] {
        #expect(throws: ConfigProblem.self, "\(text)") {
            try ConfigSecrets.removed(from: text)
        }
    }
}

/// The restored copy's own tokens go, and the live file's are put in at the values it has.
@Test func aRestoredCopyTakesTheLiveFilesSecrets() throws {
    let restored = """
        {
          "library.groupByAlbumArtist": false,
          "discogs.token": "fakeOLDtoken0nly"
        }
        """
    let live = """
        {
          "recommender.token": "\(serviceToken)",
          "discogs.token": "\(discogsToken)",
          "library.groupByAlbumArtist": true
        }
        """
    let merged = try ConfigSecrets.kept(from: live, in: restored)
    #expect(!merged.contains("fakeOLDtoken0nly"))
    let read = try values(merged)
    #expect(read["library.groupByAlbumArtist"] as? Bool == false)
    #expect((read["discogs.token"] as? DiscogsToken)?.secret == discogsToken)
    #expect((read["recommender.token"] as? ServiceToken)?.secret == serviceToken)
    // No live file sets no secret.
    let none = try values(try ConfigSecrets.kept(from: nil, in: restored))
    #expect(none["discogs.token"] == nil)
    #expect(throws: ConfigProblem.self) { try ConfigSecrets.kept(from: "{", in: restored) }
}
