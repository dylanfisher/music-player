import Settings

/// Where a watched folder's share is mounted now (ADR 0028).
enum ShareLookup: Equatable {
    case mounted(at: String)
    case unmounted
    /// No mounted share has its host, and more than one has its name, at these mount points.
    case ambiguous([String])

    /// Looks `share` up by host and name, else by name alone when exactly one mounted share has
    /// it, so `nas.local` and the NAS's IP address reach the same library.
    init(_ share: ShareURL, among mounted: [MountedShare]) {
        let parsed = mounted.compactMap { mount in
            ShareURL(mount.url).map { (url: $0, mountPoint: mount.mountPoint) }
        }
        let exact = parsed.filter { $0.url.isSameShare(as: share) }
        let found = exact.isEmpty ? parsed.filter { $0.url.hasSameName(as: share) } : exact
        switch found.count {
        case 0: self = .unmounted
        case 1: self = .mounted(at: found[0].mountPoint)
        default: self = .ambiguous(found.map(\.mountPoint).sorted())
        }
    }
}
