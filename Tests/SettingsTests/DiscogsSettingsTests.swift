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
