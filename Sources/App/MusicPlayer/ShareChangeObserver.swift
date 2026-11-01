import AppKit
import Network

/// Calls `changed` on the main thread on wake, when a volume mounts and when the network
/// changes: when a share may have been mounted somewhere new (ADR 0028). Lives as long as the
/// app.
@MainActor
final class ShareChangeObserver {
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []

    init(_ changed: @escaping @MainActor () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.didMountNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { changed() }
                })
        }
        monitor.pathUpdateHandler = { _ in MainActor.assumeIsolated { changed() } }
        monitor.start(queue: .main)
    }
}
