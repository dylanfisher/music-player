import Foundation
import Log
import MediaPlayer

private let logger = moduleLogger()

/// `RemoteCommandCenter` on the system's `MPRemoteCommandCenter`, which media keys, headphone
/// buttons and Control Center all send through.
@MainActor
public final class SystemRemoteCommands: RemoteCommandCenter {
    private let center = MPRemoteCommandCenter.shared()

    public init() {}

    public func start(_ handler: @escaping @MainActor @Sendable (RemoteAction) -> Bool) {
        for remote in RemoteCommand.allCases {
            command(remote).addTarget(handler: Self.target(remote, handler))
        }
    }

    public func setEnabled(_ enabled: Set<RemoteCommand>) {
        for remote in RemoteCommand.allCases {
            command(remote).isEnabled = enabled.contains(remote)
        }
    }

    private func command(_ remote: RemoteCommand) -> MPRemoteCommand {
        switch remote {
        case .togglePlayPause: center.togglePlayPauseCommand
        case .play: center.playCommand
        case .pause: center.pauseCommand
        case .stop: center.stopCommand
        case .nextTrack: center.nextTrackCommand
        case .previousTrack: center.previousTrackCommand
        case .changePlaybackPosition: center.changePlaybackPositionCommand
        }
    }

    /// Made outside the main actor, so the closure isn't isolated to it: the system doesn't
    /// promise to call it on the main thread. Off it, the handler runs on the main thread while
    /// this one waits, which can't deadlock because the main thread never waits on MediaPlayer's.
    nonisolated private static func target(
        _ remote: RemoteCommand, _ handler: @escaping @MainActor @Sendable (RemoteAction) -> Bool
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            let seconds = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            guard let action = RemoteAction(remote, seconds: seconds) else {
                logger.error("the system sent \(String(describing: remote)) without a position")
                return .commandFailed
            }
            let ran =
                Thread.isMainThread
                ? MainActor.assumeIsolated { handler(action) }
                : DispatchQueue.main.sync { MainActor.assumeIsolated { handler(action) } }
            guard ran else {
                logger.notice("the system sent \(String(describing: remote)), which is off now")
                return .commandFailed
            }
            return .success
        }
    }
}
