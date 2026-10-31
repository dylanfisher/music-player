import Darwin

/// A glob over a path relative to a watched folder's root. `*`, `?` and `[...]` match within one
/// path component, as `fnmatch` does; a `**` component matches any number of components,
/// including none. A pattern with no "/" matches the last component at any depth, so "*.flac"
/// means every FLAC file and "Scans" every folder or file named Scans.
struct PathPattern: Sendable {
    private let components: [String]
    private let anywhere: Bool

    init(_ pattern: String) {
        let trimmed = pattern.split(separator: "/", omittingEmptySubsequences: true).map(
            String.init)
        components = trimmed
        anywhere = !pattern.contains("/")
    }

    func matches(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        if anywhere {
            guard let last = parts.last, let pattern = components.first else { return false }
            return fnmatch(pattern, last, 0) == 0
        }
        return match(components[...], parts[...])
    }

    private func match(_ pattern: ArraySlice<String>, _ parts: ArraySlice<String>) -> Bool {
        guard let first = pattern.first else { return parts.isEmpty }
        if first == "**" {
            return (0...parts.count).contains { match(pattern.dropFirst(), parts.dropFirst($0)) }
        }
        guard let part = parts.first else { return false }
        return fnmatch(first, part, 0) == 0 && match(pattern.dropFirst(), parts.dropFirst())
    }
}

/// A watched folder's include and exclude lists. Excludes apply to folders too, so an excluded
/// folder is never walked; includes apply only to files.
struct FolderFilter: Sendable {
    private let include: [PathPattern]
    private let exclude: [PathPattern]

    init(include: [String], exclude: [String]) {
        self.include = include.map(PathPattern.init)
        self.exclude = exclude.map(PathPattern.init)
    }

    func includesDirectory(_ relativePath: String) -> Bool {
        !exclude.contains { $0.matches(relativePath) }
    }

    func includesFile(_ relativePath: String) -> Bool {
        (include.isEmpty || include.contains { $0.matches(relativePath) })
            && !exclude.contains { $0.matches(relativePath) }
    }
}
