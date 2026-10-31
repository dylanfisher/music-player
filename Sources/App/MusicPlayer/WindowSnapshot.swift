import AppKit

/// What `--snapshot-of` draws: the main window, its palette opened on ⌘K, the smart playlist
/// editor opened on a new playlist, the tag editor opened on every track, or the Settings
/// window's General or Shortcuts pane.
enum SnapshotTarget: String, CaseIterable {
    case main, palette, playlist, tags, settings, shortcuts
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
