import AppKit
import Log
import Settings

private let logger = moduleLogger()

/// Shows the files at `paths` selected in `viewer`, or in Finder when no app has Searcher's
/// bundle ID. It only reads: the files are never opened, moved or written.
public func reveal(_ paths: [String], in viewer: FileViewer) {
    let urls = paths.map { URL(fileURLWithPath: $0, isDirectory: false) }
    let workspace = NSWorkspace.shared
    guard let searcher = searcherApp(viewer, find: workspace.urlForApplication) else {
        keepRevealsInFinder()
        workspace.activateFileViewerSelecting(urls)
        return
    }
    // Searcher takes an open-documents event as a reveal: each file selected in its folder.
    workspace.open(urls, withApplicationAt: searcher, configuration: .init()) { _, error in
        if let error { logger.error("couldn't reveal the tracks in Searcher: \(error)") }
    }
}

/// Searcher's app when `viewer` is Searcher and `find` has an app for its bundle ID; nil
/// reveals in Finder.
func searcherApp(_ viewer: FileViewer, find: (String) -> URL?) -> URL? {
    switch viewer {
    case .searcher: find(viewer.bundleID)
    case .finder: nil
    }
}

/// Has this process's reveals go to Finder whatever app the global `NSFileViewer` key names, as
/// Searcher does for its own. In memory only: the argument domain wins over the global one and
/// is never written to disk (ADR 0048).
private func keepRevealsInFinder() {
    let defaults = UserDefaults.standard
    let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defaults.setVolatileDomain(
        arguments.merging(["NSFileViewer": FileViewer.finder.bundleID]) { _, finder in finder },
        forName: UserDefaults.argumentDomain)
}
