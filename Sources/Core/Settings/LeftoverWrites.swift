import Foundation
import Log

private let logger = moduleLogger()

/// The temp files a save leaves beside `file` when the process dies mid-write, named
/// `<name>.sb-<id>` as Foundation's atomic write and `writeConfigFile` name them, by path.
public func leftoverAtomicWrites(beside file: URL) -> [String] {
    let folder = file.deletingLastPathComponent()
    let prefix = file.lastPathComponent + ".sb-"
    let names: [String]
    do {
        names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    } catch CocoaError.fileReadNoSuchFile {
        return []
    } catch {
        logger.error("couldn't list \(folder.path) for saves that didn't finish: \(error)")
        return []
    }
    return names.filter { $0.hasPrefix(prefix) }.map { folder.appendingPathComponent($0).path }
}

/// Deletes `leftoverAtomicWrites(beside:)`. Nothing reads them, but one would build up per kill.
func removeLeftoverAtomicWrites(beside file: URL) {
    for path in leftoverAtomicWrites(beside: file) {
        do {
            try FileManager.default.removeItem(atPath: path)
            logger.notice("removed \(path), left by a save that didn't finish")
        } catch {
            logger.error("couldn't remove \(path), left by a save that didn't finish: \(error)")
        }
    }
}
