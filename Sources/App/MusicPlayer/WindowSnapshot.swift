import AppKit

/// What `--snapshot-of` draws: the main window, or the main window's palette opened on ⌘K.
enum SnapshotTarget: String, CaseIterable {
    case main, palette
}

/// `--snapshot <file>`: draws the window's content into a PNG, for checking the layout on a Mac
/// where screen recording isn't allowed. The app draws its own views, so it needs no permission.
@MainActor
func writeSnapshot(of window: NSWindow, to url: URL) throws {
    guard let view = window.contentView,
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { throw SnapshotError(path: url.path) }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw SnapshotError(path: url.path)
    }
    try png.write(to: url)
}

struct SnapshotError: Error, CustomStringConvertible {
    var path: String
    var description: String { "couldn't draw the window into \(path)" }
}
