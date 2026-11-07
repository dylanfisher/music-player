import Foundation
import Library
import Settings

/// Where the dumps folder is now: its path, or under where its share is mounted, found the way
/// the sync folder's share is (ADR 0028). Throws when the share isn't mounted, or when its name
/// is mounted from more than one host and which one is meant isn't known.
func locate(_ folder: DumpsFolder, among shares: [MountedShare])
    throws(CatalogImportError) -> URL
{
    switch Library.locate(SyncFolder(path: folder.path, share: folder.share), among: shares) {
    case .found(let path): return URL(fileURLWithPath: path, isDirectory: true)
    case .unmounted: throw .shareNotMounted(folder.share ?? folder.path)
    case .ambiguous(let mountPoints):
        throw .shareAmbiguous(folder.share ?? folder.path, mountPoints: mountPoints)
    }
}
