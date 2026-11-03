import AppKit
import Log
import Metadata
import Settings

private let logger = moduleLogger()

/// Shows the files at `paths` selected in `viewer`, or in Finder when no app has Searcher's
/// bundle ID. It only reads: the files are never opened, moved or written. Off the main thread,
/// since a reveal looks at the files, which may be on a share that has stopped answering.
public func reveal(_ paths: [String], in viewer: FileViewer) {
    Task { await blockingFileWork { revealNow(paths, in: viewer) } }
}

private func revealNow(_ paths: [String], in viewer: FileViewer) {
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
/// Searcher does for its own. With any key set, Finder's ID included, AppKit sends that app an
/// open-documents event, and Finder answers it by playing a track in Music; with an ID no app
/// has, AppKit reveals in Finder itself. So a set key is overridden with the empty ID, and an
/// unset one left alone. In memory only: the argument domain wins over the global one and is
/// never written to disk (ADR 0051).
func keepRevealsInFinder(
    _ defaults: UserDefaults = .standard, global: () -> String? = globalFileViewer
) {
    guard let override = fileViewerOverride(global: global()) else { return }
    let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defaults.setVolatileDomain(
        arguments.merging([fileViewerKey: override]) { _, new in new },
        forName: UserDefaults.argumentDomain)
}

let fileViewerKey = "NSFileViewer"

/// The global `NSFileViewer`, as other apps set it; nil when it's unset.
private func globalFileViewer() -> String? {
    CFPreferencesCopyValue(
        fileViewerKey as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost) as? String
}

/// The `NSFileViewer` this process sets for a reveal in Finder when the global key is
/// `global`: nil leaves an unset key alone, and the empty ID, which no app has, sends AppKit to
/// Finder.
func fileViewerOverride(global: String?) -> String? {
    global == nil ? nil : ""
}
