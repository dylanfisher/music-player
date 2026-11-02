import Settings

/// Where a watched folder's share is mounted now (ADR 0028).
enum ShareLookup: Equatable {
    case mounted(at: String)
    case unmounted
    /// No mounted share is this share on its host, and these mount points have its name on
    /// another host, which could be another server: offline rather than guessed.
    case ambiguous([String])

    /// Looks `share` up by host and name. Without a match on the host, a share with the same
    /// name counts only when one of the two hosts is an IP address and no other mounted share
    /// has the name, so the NAS reached by its address is found, but a second server with a
    /// share of the same name never is. The share mounted twice on its host, as macOS does at
    /// `/Volumes/music` and `/Volumes/music-1`, is one share: the first mount point in order
    /// stands for both (ADR 0028).
    init(_ share: ShareURL, among mounted: [MountedShare]) {
        let parsed = mounted.compactMap { mount in
            ShareURL(mount.url).map { (url: $0, mountPoint: mount.mountPoint) }
        }
        let exact = parsed.filter { $0.url.isSameShare(as: share) }.map(\.mountPoint).sorted()
        let named = parsed.filter { $0.url.hasSameName(as: share) }
        if let first = exact.first {
            self = .mounted(at: first)
        } else if named.count == 1,
            share.hostIsAddress || named[0].url.hostIsAddress
        {
            self = .mounted(at: named[0].mountPoint)
        } else if named.isEmpty {
            self = .unmounted
        } else {
            self = .ambiguous(named.map(\.mountPoint).sorted())
        }
    }
}
