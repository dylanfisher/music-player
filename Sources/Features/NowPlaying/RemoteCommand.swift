import Commands
import Playback

/// The commands the system's media keys, headphone buttons and Now Playing send. Each runs a
/// registry command, so it does what the menu item does, except the scrubber's position, which
/// carries a time no command takes.
///
/// Skip forward and back by an interval are left off: with them on, Control Center and the
/// headphones skip by seconds instead of by track.
public enum RemoteCommand: CaseIterable, Hashable, Sendable {
    case togglePlayPause, play, pause, stop, nextTrack, previousTrack
    /// Control Center's scrubber.
    case changePlaybackPosition

    /// The registry command this runs; nil for the scrubber, which seeks the engine. Play and
    /// pause run the absolute commands, so a press decided from a state that's out of date
    /// can't do the opposite.
    var commandID: CommandID? {
        switch self {
        case .togglePlayPause: .playPause
        case .play: .play
        case .pause: .pause
        case .stop: .stop
        case .nextTrack: .nextTrack
        case .previousTrack: .previousTrack
        case .changePlaybackPosition: nil
        }
    }

    /// Whether the system should offer this now. `commandIsEnabled` is the dispatcher's check,
    /// which is off until there's an engine.
    func isEnabled(_ state: PlaybackState, commandIsEnabled: (CommandID) -> Bool) -> Bool {
        let loaded = state.status != .stopped
        guard let id = commandID else { return loaded && state.durationSeconds != nil }
        guard commandIsEnabled(id) else { return false }
        return self == .stop ? loaded : state.currentIndex != nil
    }
}

/// One press or drag, as the system sends it.
public struct RemoteAction: Equatable, Sendable {
    let command: RemoteCommand
    /// Where the scrubber went; nil for every other command.
    let seconds: Double?

    /// Nil for the scrubber without a time. `seconds` is dropped for the other commands.
    public init?(_ command: RemoteCommand, seconds: Double?) {
        if command == .changePlaybackPosition, seconds == nil { return nil }
        self.command = command
        self.seconds = command == .changePlaybackPosition ? seconds : nil
    }
}
