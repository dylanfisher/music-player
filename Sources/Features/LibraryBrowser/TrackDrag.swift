import AppKit
import Log

/// What a drag of track table rows carries: each track's ID, as text, in a type only this app
/// reads. Never file URLs, which would let Finder copy or move the music files.
let trackIDsType = NSPasteboard.PasteboardType("\(bundleIdentifier).track-ids")

/// The pasteboard item for one dragged track.
func trackDragItem(_ id: Int64) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    item.setString(String(id), forType: trackIDsType)
    return item
}

/// The IDs a drag of track rows carries, in table order.
func draggedTrackIDs(_ pasteboard: NSPasteboard) -> [Int64] {
    (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: trackIDsType) }
        .compactMap { Int64($0) }
}
