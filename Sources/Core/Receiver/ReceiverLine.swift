/// A change the receiver reported, which the model takes.
public enum ReceiverEvent: Equatable, Sendable {
    case power(Bool)
    case volume(ReceiverVolume)
    case mute(Bool)
    /// Nil for an input the app has no name for.
    case input(ReceiverInput?)
    /// The receiver's own name for it: the X1800H has more modes than the X1000's spec lists.
    case soundMode(String)
}

/// One status line, read as hostile input (ADR 0039).
public enum ReceiverLine: Equatable, Sendable {
    case event(ReceiverEvent)
    /// A command the app doesn't follow, such as channel levels after a sound mode change.
    case ignored
    /// A command the app follows with a value it can't take: reported, and the model keeps
    /// what it had. An unknown input is `.event(.input(nil))` and reported too.
    case unknownValue(String)
    /// A byte outside printable ASCII, which the protocol never sends.
    case notText

    /// Longest sound mode name the spec allows.
    static let parameterCap = 25

    /// Reads a line without its carriage return.
    public init(_ bytes: ArraySlice<UInt8>) {
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else {
            self = .notText
            return
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let command = text.prefix(2)
        let value = text.dropFirst(2)
        switch command {
        case "PW":
            switch value {
            case "ON": self = .event(.power(true))
            case "STANDBY": self = .event(.power(false))
            default: self = .unknownValue(text)
            }
        case "MV":
            // The maximum the receiver allows; the app doesn't use it.
            if value.hasPrefix("MAX") {
                self = .ignored
            } else {
                self =
                    ReceiverVolume(parameter: value).map { .event(.volume($0)) }
                    ?? .unknownValue(text)
            }
        case "MU":
            switch value {
            case "ON": self = .event(.mute(true))
            case "OFF": self = .event(.mute(false))
            default: self = .unknownValue(text)
            }
        case "SI":
            self = .event(.input(ReceiverInput(rawValue: String(value))))
        case "MS":
            if value.hasPrefix("QUICK") {
                self = .ignored
            } else if value.isEmpty || value.count > Self.parameterCap {
                self = .unknownValue(text)
            } else {
                self = .event(.soundMode(String(value)))
            }
        default:
            self = .ignored
        }
    }
}

/// What the receiver last reported. It changes only on a status line, so it follows the
/// receiver's own remote and front panel, and never shows what the app sent until the
/// receiver says so.
public struct ReceiverState: Equatable, Sendable {
    public var isOn: Bool?
    public var volume: ReceiverVolume?
    public var isMuted: Bool?
    public var input: ReceiverInput?
    public var soundMode: String?

    public init() {}

    mutating func apply(_ event: ReceiverEvent) {
        switch event {
        case .power(let on): isOn = on
        case .volume(let volume): self.volume = volume
        case .mute(let muted): isMuted = muted
        case .input(let input): self.input = input
        case .soundMode(let mode): soundMode = mode
        }
    }

    /// Whether the receiver is in `mode`.
    public func isIn(_ mode: ReceiverSoundMode) -> Bool { soundMode == mode.rawValue }
}
