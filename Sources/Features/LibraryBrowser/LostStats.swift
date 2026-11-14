import AppKit
import Library
import Log

private let logger = moduleLogger()

extension LibraryBrowser {
    /// Opens Lost Stats over `window`, one lost file at a time, to give each one's stats to a
    /// track that matches it or dismiss it. When there are none, or they can't be read, a sheet
    /// on `window` says so.
    public func resolveLostStats(over window: NSWindow) {
        guard !isResolvingLostStats else {
            NSSound.beep()
            return
        }
        isResolvingLostStats = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let lost = try await reader.lostFiles()
                guard !lost.isEmpty else {
                    isResolvingLostStats = false
                    return tell(
                        "No Lost Stats to Resolve",
                        "Lost Stats lists files that left the library with plays, a rating or"
                            + " playlist entries no track has taken. There are none now.",
                        window)
                }
                let session = LostStatsSession(
                    lost: lost,
                    paths: try await reader.paths(ids: Array(Set(lost.flatMap(\.candidates)))),
                    move: { [reader] in try await reader.moveStats(from: $0, to: $1) },
                    dismiss: { [reader] in try await reader.dismissLost($0) })
                let sheet = LostStatsSheet(session: session)
                sheet.changed = { [weak self] in
                    self?.refreshNow()
                    self?.runHealth()
                    self?.edited()
                }
                sheet.failed = { [weak self] message in self?.report(message) }
                sheet.closed = { [weak self] in
                    self?.lostStatsSheet = nil
                    self?.isResolvingLostStats = false
                }
                lostStatsSheet = sheet
                sheet.begin(over: window)
            } catch {
                isResolvingLostStats = false
                logger.error("couldn't read the lost stats: \(error)")
                tell("The Lost Stats Couldn't Be Read", "\(error)", window)
            }
        }
    }
}
