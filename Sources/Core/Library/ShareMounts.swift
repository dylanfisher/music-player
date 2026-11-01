import Foundation

/// A mounted volume that macOS can mount again from a URL: a network share.
public struct MountedShare: Equatable, Sendable {
    /// The volume's remount URL, such as `smb://nas.local/music`.
    var url: String
    var mountPoint: String
}

/// The network shares mounted now. `SystemShareMounts` reads them from the system; tests fake
/// them, since no test may mount a share.
public protocol ShareMounts: Sendable {
    func mountedShares() throws -> [MountedShare]
}

public struct SystemShareMounts: ShareMounts {
    public init() {}

    /// Every mounted volume with a remount URL. Local disks have none.
    public func mountedShares() throws -> [MountedShare] {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey]
        guard
            let volumes = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys, options: [])
        else { throw CocoaError(.fileReadUnknown) }
        return try volumes.compactMap { volume in
            guard let url = try volume.resourceValues(forKeys: Set(keys)).volumeURLForRemounting
            else { return nil }
            return MountedShare(url: url.absoluteString, mountPoint: volume.path)
        }
    }
}
