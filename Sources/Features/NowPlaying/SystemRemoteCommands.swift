import Foundation
import MediaPlayer

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
    /// promise to call it on the main thread.
    nonisolated private static func target(
        _ remote: RemoteCommand, _ handler: @escaping @MainActor @Sendable (RemoteAction) -> Bool
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            let action: RemoteAction
            switch remote {
            case .togglePlayPause: action = .togglePlayPause
            case .play: action = .play
            case .pause: action = .pause
            case .stop: action = .stop
            case .nextTrack: action = .nextTrack
            case .previousTrack: action = .previousTrack
            case .changePlaybackPosition:
                guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                    return .commandFailed
                }
                action = .seek(toSeconds: event.positionTime)
            }
            guard Thread.isMainThread else {
                Task { @MainActor in _ = handler(action) }
                return .success
            }
            return MainActor.assumeIsolated { handler(action) } ? .success : .commandFailed
        }
    }
}
