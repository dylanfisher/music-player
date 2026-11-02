import AppKit

/// Opens Finder windows with the files at `paths` selected. It only reads: the files are never
/// opened, moved or written.
public func revealInFinder(_ paths: [String]) {
    NSWorkspace.shared.activateFileViewerSelecting(
        paths.map { URL(fileURLWithPath: $0, isDirectory: false) })
}
