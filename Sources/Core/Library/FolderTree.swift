import Foundation

/// The folders under each watched folder that hold tracks, worked out from the paths the index
/// holds: nothing on disk or on the NAS is read. Folders are named as the index spells them, so
/// a folder's tracks are the paths under it byte for byte.
public struct FolderTree: Equatable, Sendable {
    /// Each folder's subfolders, in Finder's order. A watched folder is keyed by its path as the
    /// settings give it; a folder with no subfolders isn't a key.
    private var subfolders: [String: [String]] = [:]
    /// Each folder below a watched folder, to the folder it sits in.
    private var parents: [String: String] = [:]

    public init() {}

    /// The tree of the folders holding `paths`, under the watched folders `roots`. A path under
    /// no root is left out; one under two nested roots belongs to the inner one.
    public init(paths: some Sequence<String>, roots: [String]) {
        // Longest first, so the inner of two nested roots wins.
        let stems = roots.map { (root: $0, stem: stem($0)) }.sorted {
            $0.stem.count > $1.stem.count
        }
        var lastFolder: Substring?
        var children: [String: Set<String>] = [:]
        for path in paths {
            guard let slash = path.lastIndex(of: "/") else { continue }
            let folder = path[..<slash]
            // Paths come in path order, so a folder's files are usually together.
            if folder == lastFolder { continue }
            lastFolder = folder
            guard let root = stems.first(where: { path.hasPrefix($0.stem + "/") }) else {
                continue
            }
            var current = String(folder)
            while current != root.stem, parents[current] == nil {
                let parent = current.lastIndex(of: "/").map { String(current[..<$0]) } ?? ""
                let key = parent == root.stem ? root.root : parent
                parents[current] = key
                children[key, default: []].insert(current)
                if parent == root.stem { break }
                current = parent
            }
        }
        subfolders = children.mapValues { folders in
            folders.sorted {
                name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending
            }
        }
    }

    /// The folders directly in `folder`, in Finder's order.
    public func subfolders(of folder: String) -> [String] {
        subfolders[folder] ?? []
    }

    /// The folders from the watched folder down to the one holding `folder`, outermost first;
    /// empty for a watched folder or a folder the tree doesn't hold.
    public func ancestors(of folder: String) -> [String] {
        var chain: [String] = []
        var current = folder
        while let parent = parents[current] {
            chain.append(parent)
            current = parent
        }
        return chain.reversed()
    }

    /// Whether `folder` is one of `roots` or under one, as a saved source must be to show.
    public static func isFolder(_ folder: String, under roots: [String]) -> Bool {
        roots.contains { $0 == folder || isPath(folder, under: $0) }
    }
}

/// A folder's last component, as the sidebar shows it.
private func name(of folder: String) -> String {
    (folder as NSString).lastPathComponent
}
