import Foundation
import Testing

@testable import Settings

private let schema = AppSettings()

private func parsed(_ text: String) throws(ConfigErrorList) -> ConfigContents {
    try ConfigFile.parse(
        ConfigText(text), settings: schema.settings, check: { _, _, _ in nil },
        conflicts: schema.conflicts)
}

/// Every problem `text` has, or nil when it parses.
private func problems(_ text: String) -> [String]? {
    do {
        _ = try parsed(text)
        return nil
    } catch {
        return error.problems.map(\.description)
    }
}

@Test func aDumpsFolderIsAPathOrAShareAndAPathInsideIt() throws {
    #expect(
        try parsed(#"{"discogs.dumpsFolder": {"share": "smb://nas/music", "path": "discogs"}}"#)
            .values["discogs.dumpsFolder"] as? DumpsFolder
            == DumpsFolder(path: "discogs", share: "smb://nas/music"))
    #expect(
        try parsed(#"{"discogs.dumpsFolder": {"path": "/Volumes/music/discogs"}}"#)
            .values["discogs.dumpsFolder"] as? DumpsFolder
            == DumpsFolder(path: "/Volumes/music/discogs"))
    for (text, problem) in [
        (#"{"discogs.dumpsFolder": {"path": "/d", "kind": "network"}}"#, "unknown key"),
        (#"{"discogs.dumpsFolder": {"path": "discogs"}}"#, "isn't absolute"),
        (
            #"{"discogs.dumpsFolder": {"share": "smb://nas/music", "path": "/discogs"}}"#,
            "can't start with /"
        ),
        (
            #"{"discogs.dumpsFolder": {"share": "smb://nas/music", "path": "../x"}}"#,
            "leaves share"
        ),
    ] {
        let found = problems(text)
        #expect(found?.count == 1, "\(text)")
        #expect(found?.first?.contains(problem) == true, "\(found ?? [])")
    }
}

@Test func theCatalogIsInTheDataFolderUnlessItsPathIsSet() {
    let paths = AppPaths(home: URL(fileURLWithPath: "/tmp/home", isDirectory: true))
    #expect(paths.discogsCatalogFile(nil).path == "/tmp/home/discogs.sqlite")
    #expect(
        paths.discogsCatalogFile("/Volumes/big/discogs.sqlite").path
            == "/Volumes/big/discogs.sqlite")
}

@Test func theCatalogPathIsAnAbsoluteFileOutsideEveryWatchedFolder() throws {
    let watched =
        #""library.watchedFolders": [{"path": "/Volumes/music/library", "kind": "network", "include": [], "exclude": [], "pollIntervalMinutes": 15}]"#
    _ = try parsed(#"{"discogs.catalogPath": "/Volumes/big/discogs.sqlite", \#(watched)}"#)
    _ = try parsed(
        #"{"discogs.catalogPath": "/Volumes/music/library-catalog.sqlite", \#(watched)}"#)
    for (path, problem) in [
        ("discogs.sqlite", "isn't the absolute path of a file"),
        ("/Volumes/big/", "isn't the absolute path of a file"),
        ("/Volumes/music/library/discogs.sqlite", "outside every watched folder"),
        ("/Volumes/music/./library/x/../discogs.sqlite", "outside every watched folder"),
    ] {
        let found = problems(#"{"discogs.catalogPath": "\#(path)", \#(watched)}"#)
        #expect(found?.count == 1, "\(path)")
        #expect(found?.first?.contains(problem) == true, "\(found ?? [])")
    }
}

/// Made up for these tests; no real token appears in a test (ADR 0137).
let fakeToken = "fakeTOKENfor3tests0nly"

@Test func theTokenReadsAsADiscogsToken() throws {
    let contents = try parsed(#"{"discogs.token": "\#(fakeToken)"}"#)
    #expect(contents.values["discogs.token"] as? DiscogsToken == DiscogsToken(fakeToken))
    #expect(try parsed(#"{"discogs.token": null}"#).values["discogs.token"] != nil)
}

@Test func theTokenNeverPrintsItsValue() throws {
    let token = DiscogsToken(fakeToken)
    let optional: DiscogsToken? = token
    var dumped = ""
    dump(token, to: &dumped)
    for text in [
        String(describing: token), "\(token)", String(reflecting: token), "\(optional as Any)",
        String(reflecting: optional), dumped,
    ] {
        #expect(!text.contains(fakeToken))
        #expect(text.contains("<Discogs token>"), "\(text)")
    }
    let decodeError = #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(DiscogsToken.self, from: Data(#"{"t": "\#(fakeToken)"}"#.utf8))
    }
    #expect(!"\(decodeError as Any)".contains(fakeToken))
}

@Test func aBadTokenIsAProblemThatNamesTheKeyButNotTheValue() {
    for json in [
        #""\#(fakeToken)\nX""#, #""\#(fakeToken) X""#, #""   ""#, #""""#, "12345",
        #""\#(fakeToken)é""#,
    ] {
        let found = problems(#"{"discogs.token": \#(json)}"#)
        #expect(found?.count == 1, "\(json)")
        #expect(found?.first?.contains("\"discogs.token\"") == true, "\(found ?? [])")
        #expect(found?.first?.contains(fakeToken) == false, "\(found ?? [])")
        #expect(found?.first?.contains("12345") == false, "\(found ?? [])")
    }
}
