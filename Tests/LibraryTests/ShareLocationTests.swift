import Foundation
import Testing

@testable import Library
@testable import Settings

/// Stands in for the system's list of mounted shares, which no test may change.
final class FakeMounts: ShareMounts, @unchecked Sendable {
    private let lock = NSLock()
    private var shares: [MountedShare]
    private var failure: (any Error)?

    init(_ shares: [MountedShare] = []) { self.shares = shares }

    func set(_ shares: [MountedShare]) { lock.withLock { self.shares = shares } }

    /// Makes every listing throw `error`, until it's nil again.
    func fail(with error: (any Error)?) { lock.withLock { failure = error } }

    func mountedShares() throws -> [MountedShare] {
        try lock.withLock {
            if let failure { throw failure }
            return shares
        }
    }
}

private let music = WatchedFolder(path: "library", share: "smb://nas.local/music", kind: .network)

private func share(_ url: String, at mountPoint: String) -> MountedShare {
    MountedShare(url: url, mountPoint: mountPoint)
}

@Test func aShareIsFoundByHostThenByNameAlone() throws {
    let stored = try #require(ShareURL("smb://NAS.local./music"))
    #expect(stored.host == "nas.local")
    let byName = share("smb://dylan@nas.local/Music", at: "/Volumes/music")
    let byIP = share("smb://192.168.1.5/music", at: "/Volumes/music-1")
    let other = share("smb://nas.local/video", at: "/Volumes/video")
    #expect(ShareLookup(stored, among: [other, byName]) == .mounted(at: "/Volumes/music"))
    // The same share reached by IP address: no host matches, and one share has the name.
    #expect(ShareLookup(stored, among: [other, byIP]) == .mounted(at: "/Volumes/music-1"))
    // By host name and by IP at once: the host decides.
    #expect(ShareLookup(stored, among: [byIP, byName]) == .mounted(at: "/Volumes/music"))
    let otherNAS = share("smb://10.0.0.9/music", at: "/Volumes/music-2")
    #expect(
        ShareLookup(stored, among: [byIP, otherNAS])
            == .ambiguous(["/Volumes/music-1", "/Volumes/music-2"]))
    #expect(ShareLookup(stored, among: [other]) == .unmounted)
    // Another server with a share of the same name, while the NAS is off: never retargeted.
    let elsewhere = share("smb://backup.local/music", at: "/Volumes/music-3")
    #expect(ShareLookup(stored, among: [elsewhere]) == .ambiguous(["/Volumes/music-3"]))
    // One host, named with or without .local or Bonjour's service label.
    for host in ["nas", "NAS.LOCAL", "nas._smb._tcp.local"] {
        #expect(
            ShareLookup(stored, among: [share("smb://\(host)/music", at: "/V/m")])
                == .mounted(at: "/V/m"), "\(host)")
    }
    // Configured by address, mounted by name.
    let byAddress = try #require(ShareURL("smb://192.168.1.5/music"))
    #expect(ShareLookup(byAddress, among: [byName]) == .mounted(at: "/Volumes/music"))
    #expect(ShareLookup(stored, among: [share("afp://nas.local/music", at: "/V/m")]) == .unmounted)
}

@Test func aShareURLNeedsAHostAndAShare() {
    #expect(ShareURL("smb://nas") == nil)
    #expect(ShareURL("smb:///music") == nil)
    #expect(ShareURL("/Volumes/music") == nil)
    #expect(ShareURL("nfs://nas/export/music")?.name == "export/music")
    #expect(ShareURL("smb://nas/My%20Music")?.name == "My Music")
}

/// An index whose files are under `root`, as a scan there would leave it, with a play on the
/// first.
private func index(under root: String, names: [String] = ["a.flac", "Caf\u{e9}/b.flac"]) throws
    -> LibraryIndex
{
    let index = try craftedIndex(names.map { Crafted(path: root + "/" + $0).scanned })
    try index.recordPlay(root + "/" + names[0], at: 100)
    return index
}

@Test func aShareRemountedAtDashOneKeepsItsTracks() throws {
    let old = canonicalPath("/V/music/library")
    let index = try index(under: old)
    let before = try #require(try index.track(path: old + "/a.flac"))
    #expect(
        try index.locate([music], among: [share("smb://nas.local/music", at: "/V/music")])
            == [WatchedFolder(path: old, kind: .network)])

    let located = try index.locate(
        [music], among: [share("smb://nas.local/music", at: "/V/music-1")])
    let new = canonicalPath("/V/music-1/library")
    #expect(located == [WatchedFolder(path: new, kind: .network)])
    #expect(try index.track(path: old + "/a.flac") == nil)
    let after = try #require(try index.track(path: new + "/a.flac"))
    #expect(after.id == before.id)
    #expect(after.playCount == 1)
    #expect(after.addedSeconds == before.addedSeconds)
    #expect(after.fileName == "a.flac")
    // The name keeps the spelling it was listed in; only the root changed.
    let accented = try #require(try index.track(path: new + "/Caf\u{e9}/b.flac"))
    #expect(accented.fileName == "b.flac")
    let stored = try index.database.prepare("SELECT path FROM paths ORDER BY id").map {
        try $0.text(0)
    }
    #expect(
        stored
            == [new + "/a.flac", new + "/Caf\u{e9}/b.flac"].map(
                \.precomposedStringWithCanonicalMapping))
    // A scan's view of the folder: every file known at its new path.
    #expect(try index.knownFiles(under: new).count == 2)
    #expect(try index.knownFiles(under: old).isEmpty)
}

@Test func anUnmountedShareKeepsItsLastRoot() throws {
    let index = try craftedIndex([])
    // Never found: its URL stands in, which no scan finds.
    #expect(
        try index.locate([music], among: [])
            == [WatchedFolder(path: "smb://nas.local/music/library", kind: .network)])
    _ = try index.locate([music], among: [share("smb://nas.local/music", at: "/V/music")])
    let offline = [WatchedFolder(path: "/V/music/library", kind: .network)]
    #expect(try index.locate([music], among: []) == offline)
    #expect(try index.lastKnownFolders([music]) == offline)
    // Mounted twice by name, on neither host: offline too.
    let twice = [
        share("smb://10.0.0.1/music", at: "/V/a"), share("smb://10.0.0.2/music", at: "/V/b"),
    ]
    #expect(try index.locate([music], among: twice) == offline)
}

@Test func aFolderStoredByPathIsAsConfigured() throws {
    let folder = WatchedFolder(path: "/Users/me/Music", kind: .local)
    #expect(try craftedIndex([]).locate([folder], among: []) == [folder])
}

@Test func theRewriteMakesWayForWhatTheNewRootHeld() throws {
    let index = try index(under: "/V/old", names: ["a.flac", "b.flac", "c.flac", "d.flac"])
    try index.recordPlay("/V/old/c.flac", at: 100)
    try index.store(["b", "c", "d"].map { Crafted(path: "/V/new/\($0).flac").scanned })
    try index.recordPlay("/V/new/c.flac", at: 200)
    try index.recordPlay("/V/new/d.flac", at: 200)
    let ids = try ["a", "b", "c", "d"].map {
        try #require(try index.track(path: "/V/old/\($0).flac")).id
    }
    let newD = try #require(try index.track(path: "/V/new/d.flac")).id
    try index.database.transaction { try index.rewritePaths(under: "/V/old", to: "/V/new") }
    // a moved; b's stat-less twin gave way. The new root's files are dropped for the next
    // scan to read again, so only a and b are in the index there now.
    #expect(try index.track(path: "/V/new/a.flac")?.id == ids[0])
    #expect(try index.track(path: "/V/new/b.flac")?.id == ids[1])
    #expect(Set(try index.knownFiles(under: "/V/new").map(\.value.id)) == [ids[0], ids[1]])
    #expect(try index.knownFiles(under: "/V/old").isEmpty)
    // Both c's have stats, so the old one stays behind, lost; the old d had none and gave way.
    // The new c and d are lost too until the next scan reads their files again.
    #expect(
        try index.lostFiles().map(\.path) == ["/V/new/c.flac", "/V/new/d.flac", "/V/old/c.flac"])
    let paths = try index.database.prepare("SELECT id FROM paths WHERE path = ?").map(
        "/V/new/d.flac"
    ) { try $0.int64(0) }
    #expect(paths == [newD])
    #expect(
        !(try index.database.prepare("SELECT id FROM paths").map { try $0.int64(0) }).contains(
            ids[3]))
    #expect(throws: LibraryError.nestedRoots("/V/new", "/V/new/inner")) {
        try index.database.transaction {
            try index.rewritePaths(under: "/V/new", to: "/V/new/inner")
        }
    }
}

@Test func aPickedFolderOnAShareIsStoredByShare() {
    let shares = [
        share("smb://nas/music", at: "/Volumes/music"), share("smb://nas/x", at: "/Volumes/m"),
    ]
    #expect(
        folderToWatch(
            "/Volumes/music/Caf\u{e9}".decomposedStringWithCanonicalMapping, isLocal: false,
            among: shares)
            == WatchedFolder(path: "Caf\u{e9}", share: "smb://nas/music", kind: .network))
    #expect(
        folderToWatch("/Volumes/music", isLocal: false, among: shares)
            == WatchedFolder(path: "", share: "smb://nas/music", kind: .network))
    #expect(
        folderToWatch("/Volumes/musical", isLocal: false, among: shares)
            == WatchedFolder(path: "/Volumes/musical", kind: .network))
    #expect(
        folderToWatch("/Users/me/Music", isLocal: true, among: shares)
            == WatchedFolder(path: "/Users/me/Music", kind: .local))
}

@Test func removingAShareFolderMatchesItWhereItIs() throws {
    let index = try craftedIndex([])
    _ = try index.locate([music], among: [share("smb://nas.local/music", at: "/V/music")])
    let local = WatchedFolder(path: "/M", kind: .local)
    #expect(try index.folders([local, music], without: "/V/music/library") == [local])
    #expect(try index.folders([local, music], without: "/M") == [music])
}

@Test func aRefusedRewriteLeavesTheFolderWhereItWasAndFindsTheOthers() throws {
    let index = try craftedIndex([])
    let video = WatchedFolder(path: "", share: "smb://nas.local/video", kind: .network)
    _ = try index.locate([music], among: [share("smb://nas.local/music", at: "/V/music")])
    // Mounted again inside its old folder, which a prefix rewrite would mix up.
    let located = try index.locate(
        [music, video],
        among: [
            share("smb://nas.local/music", at: "/V/music/library/x"),
            share("smb://nas.local/video", at: "/V/video"),
        ])
    #expect(
        located == [
            WatchedFolder(path: "/V/music/library", kind: .network),
            WatchedFolder(path: "/V/video", kind: .network),
        ])
}

@Test func theMountTableNamesEachNetworkVolumesShare() {
    #expect(
        shareURL(fileSystem: "smbfs", mountedFrom: "//dylan@nas.local/music")
            == "smb://dylan@nas.local/music")
    #expect(shareURL(fileSystem: "smbfs", mountedFrom: "//nas/My Music") == "smb://nas/My%20Music")
    #expect(
        shareURL(fileSystem: "smbfs", mountedFrom: "//nas/My%20Music") == "smb://nas/My%20Music")
    #expect(shareURL(fileSystem: "afpfs", mountedFrom: "//nas/music") == "afp://nas/music")
    #expect(
        shareURL(fileSystem: "nfs", mountedFrom: "nas:/export/music") == "nfs://nas/export/music")
    #expect(shareURL(fileSystem: "apfs", mountedFrom: "/dev/disk3s1") == nil)
    #expect(
        ShareURL(shareURL(fileSystem: "smbfs", mountedFrom: "//nas/My Music")!)?.name == "My Music")
}

@Test func theSystemsMountTableReadsWithoutError() throws {
    // This machine mounts no share in tests; the listing itself must not fail.
    _ = try SystemShareMounts().mountedShares()
}

@Test func pathsWithLoggedPlaysOrImportCountsAreRewrittenAndMoved() throws {
    let index = try index(under: "/V/old", names: ["a.flac", "b.flac"])
    try index.store(["a", "b"].map { Crafted(path: "/V/new/\($0).flac").scanned })
    let newA = try #require(try index.track(path: "/V/new/a.flac")).id
    let newB = try #require(try index.track(path: "/V/new/b.flac")).id
    // A logged play with no count, and an import that counted nothing: rows that refer to the
    // new paths without making plays rows.
    try index.database.execute(
        """
        INSERT INTO history (path_id, played_at) VALUES (\(newA), 1);
        INSERT INTO \(importedPlaysTable) (player, path_id, play_count, skip_count)
            VALUES ('swinsian', \(newB), 0, 0)
        """)
    try index.database.transaction { try index.rewritePaths(under: "/V/old", to: "/V/new") }
    let paths = try index.database.prepare("SELECT id FROM paths WHERE path = ?").map(
        "/V/new/a.flac"
    ) { try $0.int64(0) }
    #expect(paths == [newA], "the logged play counts as stats, so the new a stays")
    #expect(try index.track(path: "/V/new/b.flac") != nil)
    #expect(try index.track(path: "/V/new/b.flac")?.id != newB, "the old b took its place")
}

@Test func aMoveOntoAPathWithAnImportCountOfNothingSucceeds() throws {
    let index = try craftedIndex([])
    try index.store([Crafted(path: "/M/a.flac", seconds: 77).scanned])
    try index.recordPlay("/M/a.flac", at: 1)
    let id = try #require(try index.track(path: "/M/a.flac")).id
    try index.remove([id])
    try index.store([Crafted(path: "/M/b.flac", seconds: 77).scanned])
    let new = try #require(try index.track(path: "/M/b.flac")).id
    try index.database.execute(
        "INSERT INTO \(importedPlaysTable) (player, path_id, play_count, skip_count) VALUES ('itunes', \(new), 0, 0)"
    )
    #expect(try index.matchMoves().count == 1)
    #expect(try index.track(path: "/M/b.flac")?.id == id)
}
