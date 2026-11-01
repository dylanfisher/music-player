import Testing

@testable import Library
@testable import Settings

@Test func theFolderTreeHoldsEveryFolderWithTracksUnderARoot() {
    let paths = [
        "/M/Artist/Album 10/01.flac", "/M/Artist/Album 2/01.flac", "/M/Artist/Album 2/02.flac",
        "/M/Artist/Album 2/CD1/01.flac", "/M/loose.flac", "/M/Other/x.flac", "/Elsewhere/y.flac",
        "/M/Inner/Deep/z.flac",
    ]
    let tree = FolderTree(paths: paths, roots: ["/M", "/M/Inner"])
    #expect(tree.subfolders(of: "/M") == ["/M/Artist", "/M/Other"])
    // Finder's order: 2 before 10.
    #expect(tree.subfolders(of: "/M/Artist") == ["/M/Artist/Album 2", "/M/Artist/Album 10"])
    #expect(tree.subfolders(of: "/M/Artist/Album 2") == ["/M/Artist/Album 2/CD1"])
    #expect(tree.subfolders(of: "/M/Other").isEmpty)
    // A nested root holds its own folders.
    #expect(tree.subfolders(of: "/M/Inner") == ["/M/Inner/Deep"])
    #expect(
        tree.ancestors(of: "/M/Artist/Album 2/CD1") == ["/M", "/M/Artist", "/M/Artist/Album 2"])
    #expect(tree.ancestors(of: "/M").isEmpty)
    #expect(tree.ancestors(of: "/Elsewhere").isEmpty)
    #expect(FolderTree.isFolder("/M/Artist", under: ["/M"]))
    #expect(FolderTree.isFolder("/M", under: ["/M"]))
    #expect(!FolderTree.isFolder("/Music", under: ["/M"]))
}

@Test func theFolderTreeComesFromTheIndexsTracksAndASubfolderIsASource() throws {
    let index = try craftedIndex([
        Crafted(path: "/M/A/01.flac", title: "One").scanned,
        Crafted(path: "/M/A/CD1/01.flac", title: "Two").scanned,
        Crafted(path: "/M/B/01.flac", title: "Three").scanned, failed("/M/Bad/x.flac"),
    ])
    let tree = try index.folderTree(roots: ["/M"])
    // A folder of files that were never read holds no tracks to list.
    #expect(tree.subfolders(of: "/M") == ["/M/A", "/M/B"])
    #expect(tree.subfolders(of: "/M/A") == ["/M/A/CD1"])
    let filter = TrackFilter(source: .folder("/M/A"))
    #expect(
        try index.trackIDs(filter, sortedBy: .path)
            == (try ids(index, ["/M/A/01.flac", "/M/A/CD1/01.flac"])))
}

@Test func aSubfolderSpelledPrecomposedUnderADecomposedRootIsFound() throws {
    // A share's root is stored decomposed and its names as the server lists them (ADR 0032).
    let root = "/Volumes/Mu\u{301}sic"
    let folder = root + "/Caf\u{E9}"
    let index = try craftedIndex([Crafted(path: folder + "/01.flac", title: "One").scanned])
    let tree = try index.folderTree(roots: [root])
    #expect(tree.subfolders(of: root) == [folder])
    #expect(try index.trackIDs(TrackFilter(source: .folder(folder)), sortedBy: .path).count == 1)
}
