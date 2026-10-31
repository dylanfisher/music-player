import AppKit
import Library
import Settings

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var watcher: LibraryWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = ProcessInfo.processInfo.processName
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        startLibrary()
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
    }

    /// Scans the watched folders from Settings and keeps watching them.
    private func startLibrary() {
        do {
            let settingsURL = try defaultSettingsFileURL()
            let watcher = LibraryWatcher(
                settings: try SettingsStore(AppSettings(), fileURL: settingsURL),
                databaseURL: defaultLibraryFileURL(settingsFileURL: settingsURL))
            watcher.start()
            self.watcher = watcher
        } catch {
            let alert = NSAlert()
            alert.messageText = "The library couldn't start"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
