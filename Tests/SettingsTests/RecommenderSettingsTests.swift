import Foundation
import Testing

@testable import Settings

private let schema = AppSettings()
private let token = "s3cret-token-0123456789abcdef"

private func parsed(_ text: String) throws(ConfigErrorList) -> ConfigContents {
    try ConfigFile.parse(
        ConfigText(text), settings: schema.settings, check: { _, _, _ in nil },
        conflicts: schema.conflicts)
}

/// A config file in a fresh temporary folder that nothing else touches.
private func configURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("recommender-\(UUID().uuidString)/config.json")
}

@MainActor
private func store(_ url: URL) -> ConfigStore<AppSettings> {
    ConfigStore(schema, fileURL: url, check: { _, _, _ in nil }, creating: false)
}

private func mode(_ url: URL) throws -> Int {
    try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
}

@Test func theServiceIsOffUntilItsAddressAndTokenAreSet() {
    #expect(schema.recommenderAddress.defaultValue == nil)
    #expect(schema.recommenderPort.defaultValue == 7878)
    #expect(schema.recommenderToken.defaultValue == nil)
    #expect(schema.stagingFolder.defaultValue == nil)
}

@Test func theServiceAddressIsALiteralAndThePortIsInRange() throws {
    let values = try parsed(#"{"recommender.address": "192.0.2.20", "recommender.port": 1}"#)
        .values
    #expect((values["recommender.address"] as? IPAddressSetting)?.address != nil)
    for text in [
        #"{"recommender.address": "mbp2021.local"}"#,
        #"{"recommender.address": "192.0.2.20:7878"}"#,
        #"{"recommender.port": 0}"#, #"{"recommender.port": 65536}"#,
    ] {
        #expect(throws: ConfigErrorList.self, "\(text)") { try parsed(text) }
    }
}

@Test func theServiceTokenNeverPrintsItsValue() throws {
    let value = try #require(
        try parsed(#"{"recommender.token": "\#(token)"}"#).values["recommender.token"]
            as? ServiceToken)
    #expect(value.secret == token)
    let optional: ServiceToken? = value
    var dumped = ""
    dump(value, to: &dumped)
    for text in [
        String(describing: value), "\(value)", String(reflecting: value), "\(optional as Any)",
        String(reflecting: optional), dumped,
    ] {
        #expect(!text.contains(token))
        #expect(text.contains("<service token>"), "\(text)")
    }
}

@Test func aRefusedServiceTokenIsNotInTheProblem() throws {
    for bad in ["\(token) with spaces", "", String(repeating: "x", count: 1025)] {
        do {
            _ = try parsed(#"{"recommender.token": "\#(bad)"}"#)
            Issue.record("accepted \(bad.count) characters")
        } catch {
            #expect(error.problems.count == 1)
            #expect(!"\(error)".contains(token), "\(error.problems.count) problems")
            if bad.count > 4 { #expect(!"\(error)".contains(bad)) }
        }
    }
}

@MainActor @Test func aServiceTokenInAFileOthersCanReadIsntUsed() throws {
    let url = configURL()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"recommender.port": 7000, "recommender.token": "\#(token)"}"#.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    let settings = store(url)
    #expect(settings.problems.count == 1)
    #expect(settings.problems.first?.message.contains("\"recommender.token\"") == true)
    #expect(settings.problems.first?.message.contains(token) == false)
    #expect(!settings.blocked)
    #expect(settings[\.recommenderToken] == nil)
    #expect(settings[\.recommenderPort] == 7000)
    #expect(try mode(url) == 0o644, "the app leaves the mode to the owner until it writes")
    try settings.set(\.recommenderPort, to: 7001)
    #expect(try mode(url) == 0o600)
    #expect(settings.problems.isEmpty)
    #expect(settings[\.recommenderToken]?.secret == token)
}

/// A config file with `staging` as the staging folder, `folders` as the watched folders, and
/// optionally a library folder, a sync folder and a snapshot folder.
private func config(
    staging: String, folders: [String] = [], library: String? = nil, sync: String? = nil,
    snapshots: String? = nil
) -> String {
    let watched = folders.map {
        #"{\#($0), "kind": "network", "include": [], "exclude": [], "pollIntervalMinutes": 15}"#
    }
    var keys = [
        #""import.stagingFolder": {\#(staging)}"#,
        #""library.watchedFolders": [\#(watched.joined(separator: ", "))]"#,
    ]
    if let library { keys.append(#""library.folder": "\#(library)""#) }
    if let sync { keys.append(#""sync.folder": {\#(sync)}"#) }
    if let snapshots { keys.append(#""library.snapshotFolder": "\#(snapshots)""#) }
    return "{" + keys.joined(separator: ", ") + "}"
}

@Test func theStagingFolderIsOutsideEveryFolderTheAppReadsOrWrites() throws {
    let refused = [
        config(
            staging: #""path": "/Volumes/music/library/staging""#,
            folders: [#""path": "/Volumes/music/library""#]),
        config(
            staging: #""share": "smb://nas/music", "path": "library/staging""#,
            folders: [#""share": "smb://192.168.1.5/Music", "path": "library""#]),
        config(
            staging: #""share": "smb://nas/music", "path": "staging""#,
            folders: [#""share": "smb://nas/music", "path": """#]),
        // A watched folder inside staging would scan the downloads.
        config(
            staging: #""path": "/Volumes/music""#,
            folders: [#""path": "/Volumes/music/library""#]),
        config(
            staging: #""path": "/Volumes/music/library/new""#, library: "/Volumes/music/library"),
        config(staging: #""path": "/Volumes/music""#, library: "/Volumes/music/library"),
        config(
            staging: #""share": "smb://nas/music", "path": "music-player/staging""#,
            sync: #""share": "smb://nas/music", "path": "music-player""#),
        config(
            staging: #""path": "/Volumes/music/staging""#,
            sync: #""path": "/Volumes/music/staging/sync""#),
        // The service would delete the snapshots.
        config(staging: #""path": "/Users/me/Backups""#, snapshots: "/Users/me/Backups/library"),
        config(staging: #""path": "/Users/me/Backups/staging""#, snapshots: "/Users/me/Backups"),
    ]
    for text in refused {
        do {
            _ = try parsed(text)
            Issue.record("accepted \(text)")
        } catch {
            #expect(error.problems.count == 1, "\(error)")
            #expect(error.problems.first?.message.contains("staging folder") == true, "\(error)")
        }
    }
    let accepted = [
        config(
            staging: #""path": "/Volumes/music/staging""#,
            folders: [#""path": "/Volumes/music/library""#, #""path": "/Volumes/music/dsd""#],
            library: "/Volumes/music/library", sync: #""path": "/Volumes/music/music-player""#),
        config(
            staging: #""share": "smb://nas/music", "path": "staging""#,
            folders: [#""share": "smb://nas/music", "path": "library""#],
            sync: #""share": "smb://nas/music", "path": "music-player""#),
        config(
            staging: #""path": "/Volumes/music/library-staging""#,
            folders: [#""path": "/Volumes/music/library""#]),
    ]
    for text in accepted { _ = try parsed(text) }
}

@MainActor @Test func theStagingFolderIsCheckedAgainWhenTheOtherFoldersChange() throws {
    let url = configURL()
    let settings = store(url)
    try settings.set(\.stagingFolder, to: StagingFolder(path: "/Volumes/music/staging"))
    try settings.set(
        \.watchedFolders, to: [WatchedFolder(path: "/Volumes/music/library", kind: .network)])
    #expect(throws: ConfigError.self) {
        try settings.set(
            \.watchedFolders, to: [WatchedFolder(path: "/Volumes/music", kind: .network)])
    }
    #expect(
        settings[\.watchedFolders] == [
            WatchedFolder(path: "/Volumes/music/library", kind: .network)
        ])
    #expect(throws: ConfigError.self) {
        try settings.set(\.libraryFolder, to: "/Volumes/music/staging/library")
    }
    #expect(throws: ConfigError.self) {
        try settings.set(\.syncFolder, to: SyncFolder(path: "/Volumes/music"))
    }
    // An edit in the file that puts the staging folder in a watched folder blocks the file.
    try Data(
        config(
            staging: #""path": "/Volumes/music/staging""#,
            folders: [#""path": "/Volumes/music""#]
        ).utf8
    ).write(to: url)
    settings.read(confirmed: true)
    #expect(settings.blocked)
    #expect(settings.problems.first?.message.contains("staging folder") == true)
}
