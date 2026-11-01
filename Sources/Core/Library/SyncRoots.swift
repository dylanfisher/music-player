import Settings

/// Where this machine has each share folder (ADR 0038), from `share_roots`: maps a path in
/// `paths` to its sync path, the share's name, the folder's path in the share and the path
/// under it, and back. Folders stored by path aren't synced.
struct SyncRoots {
    private struct Root {
        /// "music/library", in NFC.
        var prefix: String
        /// The folder's path here, in NFC, as `paths.path` starts.
        var root: String
    }

    private let roots: [Root]

    /// From `share_roots` rows: each folder's share URL, its path inside it and its root here.
    init(_ rows: [(share: String, innerPath: String, root: String)]) {
        roots = rows.compactMap { row in
            guard let share = ShareURL(row.share) else { return nil }
            let name = share.name.lowercased()
            let inner = row.innerPath.precomposedStringWithCanonicalMapping
            return Root(
                prefix: inner.isEmpty ? name : name + "/" + inner,
                root: stem(row.root).precomposedStringWithCanonicalMapping)
        }
        // Longest first, so a folder inside another's share path maps by its own.
        .sorted { $0.root.utf8.count > $1.root.utf8.count }
    }

    var isEmpty: Bool { roots.isEmpty }

    /// The sync path of `path`, a `paths.path` in NFC; nil outside every share folder.
    func syncPath(_ path: String) -> String? {
        for root in roots {
            if let rest = path.droppingBytes(root.root + "/") { return root.prefix + "/" + rest }
        }
        return nil
    }

    /// Where `syncPath` is on this machine; nil outside its share folders.
    func localPath(_ syncPath: String) -> String? {
        let match = roots.compactMap { root in
            syncPath.droppingBytes(root.prefix + "/").map { (root, $0) }
        }.max { $0.0.prefix.utf8.count < $1.0.prefix.utf8.count }
        return match.map { $0.0.root + "/" + $0.1 }
    }
}

extension String {
    /// What follows `prefix`, compared byte for byte rather than by characters, so a name that
    /// starts with a combining mark still follows its folder's slash; nil without the prefix.
    fileprivate func droppingBytes(_ prefix: String) -> Substring? {
        guard utf8.starts(with: prefix.utf8) else { return nil }
        return self[utf8.index(utf8.startIndex, offsetBy: prefix.utf8.count)...]
    }
}
