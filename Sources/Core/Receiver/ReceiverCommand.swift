/// What the app sends the receiver. Each is built from these typed values, never from text the
/// receiver or anyone else sent, so a command can't carry a line of its own (ADR 0039).
public enum ReceiverCommand: Equatable, Sendable {
    case volumeUp
    case volumeDown
    case setVolume(ReceiverVolume)
    case mute(Bool)
    case soundMode(ReceiverSoundMode)
    case input(ReceiverInput)
    /// On, or standby.
    case power(Bool)

    /// The line it sends, its carriage return included.
    var line: [UInt8] {
        let text =
            switch self {
            case .volumeUp: "MVUP"
            case .volumeDown: "MVDOWN"
            case .setVolume(let volume): "MV" + volume.parameter
            case .mute(let on): on ? "MUON" : "MUOFF"
            case .soundMode(let mode): "MS" + mode.rawValue
            case .input(let input): "SI" + input.rawValue
            case .power(let on): on ? "PWON" : "PWSTANDBY"
            }
        return Array((text + "\r").utf8)
    }
}

/// The requests for the state the app follows, sent once a connection opens. Each answer
/// comes back as a status line, as a change would.
let statusQueries: [[UInt8]] = ["PW?", "MV?", "MU?", "SI?", "MS?"].map { Array(($0 + "\r").utf8) }
