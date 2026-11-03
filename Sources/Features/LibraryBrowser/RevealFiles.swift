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
/// Searcher does for its own. With the key naming Finder, AppKit sends Finder an open-documents
/// event, which plays a track in Music; with an ID no app has, it reveals in Finder itself. So
/// the key is overridden only when the global one names another app. In memory only: the
/// argument domain wins over the global one and is never written to disk (ADR 0051).
private func keepRevealsInFinder() {
    let global = CFPreferencesCopyValue(
        fileViewerKey as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost)
    guard let override = fileViewerOverride(global: global as? String) else { return }
    let defaults = UserDefaults.standard
    let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defaults.setVolatileDomain(
        arguments.merging([fileViewerKey: override]) { _, new in new },
        forName: UserDefaults.argumentDomain)
}

private let fileViewerKey = "NSFileViewer"

/// The `NSFileViewer` this process sets for a reveal in Finder when the global key is
/// `global`: nil leaves it alone, and the empty ID, which no app has, sends AppKit to Finder.
func fileViewerOverride(global: String?) -> String? {
    guard let global, global != FileViewer.finder.bundleID else { return nil }
    return ""
}
