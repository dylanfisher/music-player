import LocalNetwork

/// A MediaRenderer found on a local subnet, and what it plays. Only discovery makes one, so
/// an address that came from anywhere but SSDP on the local subnet can't become a renderer.
public struct Renderer: Equatable, Sendable {
    /// Its unique device name, `uuid:…`, which `output.renderer` stores.
    public let udn: String
    /// Display text, escaped. For a Sonos player, its room, or its group's name once the
    /// topology has been read (ADR 0091).
    public internal(set) var name: String
    public let manufacturer: String
    public let model: String
    /// Where its description is; its host is the renderer's address.
    public let location: LocalURL
    /// Empty when `GetProtocolInfo` failed, and then `formatsProblem` says why.
    let sinkFormats: [ProtocolInfo]
    public let formatsProblem: String?
    /// Where to send AVTransport actions, nil when the renderer can't be played to, and then
    /// `transportProblem` says why.
    package let transport: Transport?
    public let transportProblem: String?
    /// Nil for anything but a Sonos player.
    package internal(set) var sonos: Sonos?

    /// What a Sonos player's description and the household's topology say about it.
    package struct Sonos: Equatable, Sendable {
        /// `RINCON_…`, its root device's UDN without `uuid:`, as the topology names it.
        package let playerID: String
        /// Its ZoneGroupTopology control URL, on the renderer's host.
        let topology: LocalURL
        /// The player that plays for its group, by player ID; nil until the topology has been
        /// read, or when the player isn't in it.
        package internal(set) var coordinator: String?
    }

    /// A Sonos player whose group another player leads, which plays for it: it isn't offered
    /// as an output, and a track for it goes to the coordinator.
    package var isGroupMember: Bool {
        guard let sonos, let coordinator = sonos.coordinator else { return false }
        return coordinator != sonos.playerID
    }

    /// AVTransport's control URL and its service description's, each on the renderer's host.
    package struct Transport: Equatable, Sendable {
        package let control: LocalURL
        /// Nil when the description lists no SCPDURL.
        package let description: LocalURL?
    }

    init(
        udn: String, name: String, manufacturer: String, model: String, location: LocalURL,
        sinkFormats: [ProtocolInfo], formatsProblem: String? = nil, transport: Transport? = nil,
        transportProblem: String? = nil, sonos: Sonos? = nil
    ) {
        self.udn = udn
        self.name = name
        self.manufacturer = manufacturer
        self.model = model
        self.location = location
        self.sinkFormats = sinkFormats
        self.formatsProblem = formatsProblem
        self.transport = transport
        self.transportProblem = transportProblem
        self.sonos = sonos
    }

    public var address: IPAddress { location.host }

    /// Made by Denon, as receivers and HEOS speakers are.
    package var isDenon: Bool { manufacturer.lowercased().contains("denon") }

    /// A Denon receiver rather than a speaker: its model name says AVR, as the X1800H's does.
    /// Its volume is the receiver's, which receiver control sets over its control port.
    package var isDenonReceiver: Bool { isDenon && model.uppercased().contains("AVR") }
}
