import AppKit
import Log

/// What a drag of track rows carries for the app's own drops: each track's ID, as text, in a
/// type only this app reads. The app's lists and sidebar take a drag by these, whatever else
/// it carries.
let trackIDsType = NSPasteboard.PasteboardType("\(bundleIdentifier).track-ids")

/// The pasteboard item for one dragged track: its ID, and its file's URL when `path` is known,
/// so a drag to Finder or another app hands it the file. Outside the app such a drag offers a
/// copy only (`dragOperationMask`), so Finder never moves or trashes a library file (ADR 0141).
func trackDragItem(_ id: Int64, path: String?) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    item.setString(String(id), forType: trackIDsType)
    if let path {
        item.setString(
            URL(fileURLWithPath: path, isDirectory: false).absoluteString, forType: .fileURL)
    }
    return item
}

/// The IDs a drag of track rows carries, in table order.
func draggedTrackIDs(_ pasteboard: NSPasteboard) -> [Int64] {
    (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: trackIDsType) }
        .compactMap { Int64($0) }
}
