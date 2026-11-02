import LocalNetwork

/// A MediaRenderer found on a local subnet, and what it plays. Only discovery makes one, so
/// an address that came from anywhere but SSDP on the local subnet can't become a renderer.
public struct Renderer: Equatable, Sendable {
    let udn: String
    /// Display text, escaped.
    public let name: String
    public let manufacturer: String
    public let model: String
    /// Where its description is; its host is the renderer's address.
    public let location: LocalURL
    /// Empty when `GetProtocolInfo` failed, and then `formatsProblem` says why.
    let sinkFormats: [ProtocolInfo]
    public let formatsProblem: String?

    init(
        udn: String, name: String, manufacturer: String, model: String, location: LocalURL,
        sinkFormats: [ProtocolInfo], formatsProblem: String? = nil
    ) {
        self.udn = udn
        self.name = name
        self.manufacturer = manufacturer
        self.model = model
        self.location = location
        self.sinkFormats = sinkFormats
        self.formatsProblem = formatsProblem
    }

    public var address: IPAddress { location.host }
}
