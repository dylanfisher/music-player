import Darwin
import Foundation

/// A mounted volume that macOS can mount again from a URL: a network share.
public struct MountedShare: Equatable, Sendable {
    /// The share as a URL, such as `smb://nas.local/music`.
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

    /// Every mounted SMB, AFP and NFS volume, from the kernel's mount table as it last cached
    /// it (`MNT_NOWAIT`), so no volume is asked anything: a hung share can't block the listing
    /// (ADR 0028).
    public func mountedShares() throws -> [MountedShare] {
        var table: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&table, MNT_NOWAIT)
        guard count > 0, let table else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (0..<Int(count)).compactMap { index in
            var entry = table[index]
            let type = withUnsafeBytes(of: &entry.f_fstypename) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            let from = withUnsafeBytes(of: &entry.f_mntfromname) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            let point = withUnsafeBytes(of: &entry.f_mntonname) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            return shareURL(fileSystem: type, mountedFrom: from).map {
                MountedShare(url: $0, mountPoint: point)
            }
        }
    }
}

/// The share a network volume was mounted from, as a URL, from the mount table's file system
/// type and source: `//user@nas/music` on `smbfs` is `smb://user@nas/music`, and `nas:/export`
/// on `nfs` is `nfs://nas/export`. Nil for any other file system.
func shareURL(fileSystem: String, mountedFrom raw: String) -> String? {
    // The table can hold a space or other character a URL escapes; one it escaped stays.
    let source = raw.addingPercentEncoding(withAllowedCharacters: sourceCharacters) ?? raw
    return switch fileSystem {
    case "smbfs" where source.hasPrefix("//"): "smb:" + source
    case "afpfs" where source.hasPrefix("//"): "afp:" + source
    case "nfs":
        source.firstIndex(of: ":").map { colon in
            "nfs://" + source[..<colon] + source[source.index(after: colon)...]
        }
    default: nil
    }
}

private let sourceCharacters = CharacterSet.urlPathAllowed.union(CharacterSet(charactersIn: "%@:"))
