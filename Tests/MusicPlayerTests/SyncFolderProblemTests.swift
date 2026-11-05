import AppKit
import Library
import Testing

@testable import MusicPlayer

@Test func openingTheSyncFolderSaysWhyItCant() {
    let missing = syncFolderProblem(.found("/Users/me/Sync"), share: "/Users/me/Sync")
    #expect(missing.0 == "The sync folder is missing: /Users/me/Sync")
    let unmounted = syncFolderProblem(.unmounted, share: "smb://nas.local/music")
    #expect(unmounted.0 == "The sync folder's share isn't mounted")
    #expect(unmounted.1.contains("smb://nas.local/music"))
    let ambiguous = syncFolderProblem(
        .ambiguous(["/Volumes/music", "/Volumes/music-1"]), share: "smb://nas.local/music")
    #expect(ambiguous.0 != unmounted.0)
    #expect(ambiguous.1.contains("/Volumes/music, /Volumes/music-1"))
}

@MainActor @Test func changeOpensThePanelAtTheSyncFolder() {
    let folder = FileManager.default.temporaryDirectory.standardizedFileURL.path
    #expect(syncFolderPanel(at: folder).directoryURL?.standardizedFileURL.path == folder)
}
