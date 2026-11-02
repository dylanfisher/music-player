/// An input the app can switch the receiver to, by its `SI` parameter. The list is the
/// X1000's spec less its network services, plus inputs the X1800H has; ADR 0039 says which the
/// owner has used on the real receiver and marks the rest †.
public enum ReceiverInput: String, CaseIterable, Sendable {
    case phono = "PHONO"
    case cd = "CD"
    case tuner = "TUNER"
    case dvd = "DVD"
    case bluRay = "BD"
    case tv = "TV"
    case cableSatellite = "SAT/CBL"
    case mediaPlayer = "MPLAY"
    case game = "GAME"
    case aux = "AUX1"
    case network = "NET"
    case bluetooth = "BT"

    /// As the receiver's own menus name it.
    public var title: String {
        switch self {
        case .phono: "Phono"
        case .cd: "CD"
        case .tuner: "Tuner"
        case .dvd: "DVD"
        case .bluRay: "Blu-ray"
        case .tv: "TV Audio"
        case .cableSatellite: "CBL/SAT"
        case .mediaPlayer: "Media Player"
        case .game: "Game"
        case .aux: "AUX"
        case .network: "HEOS"
        case .bluetooth: "Bluetooth"
        }
    }
}

/// A sound mode the app can choose, by its `MS` parameter.
public enum ReceiverSoundMode: String, CaseIterable, Sendable {
    case pureDirect = "PURE DIRECT"
    case direct = "DIRECT"
    case stereo = "STEREO"

    public var title: String {
        switch self {
        case .pureDirect: "Pure Direct"
        case .direct: "Direct"
        case .stereo: "Stereo"
        }
    }
}
