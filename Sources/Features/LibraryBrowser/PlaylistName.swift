/// The names the sidebar gives playlists it copies or renames.
enum PlaylistName {
    /// "Mix copy", or "Mix copy 2" and on when that's taken, as Finder names a duplicate. Names
    /// compare ignoring case, as the sidebar sorts them.
    static func copy(of name: String, taken: [String]) -> String {
        let names = Set(taken.map { $0.lowercased() })
        let base = name + " copy"
        var candidate = base
        var number = 1
        while names.contains(candidate.lowercased()) {
            number += 1
            candidate = "\(base) \(number)"
        }
        return candidate
    }

    /// The name typed over `name` in the sidebar, trimmed; nil when it changes nothing, as an
    /// empty name or the same one does.
    static func edited(_ typed: String, from name: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == name ? nil : trimmed
    }
}
