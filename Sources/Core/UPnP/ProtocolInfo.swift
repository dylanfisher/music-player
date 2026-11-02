/// One entry of a renderer's `GetProtocolInfo` sink list, `http-get:*:audio/flac:*`: what it
/// takes over which transport (ADR 0039). 9b matches tracks against these.
public struct ProtocolInfo: Equatable, Sendable, CustomStringConvertible {
    var transport: String
    var network: String
    var contentFormat: String
    var additionalInfo: String

    /// Most entries a sink list keeps.
    static let entryCap = 1024

    /// Parses one entry; nil unless it has exactly four parts.
    init?(_ text: Substring) {
        let parts = text.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, !parts[0].isEmpty, !parts[2].isEmpty else { return nil }
        transport = String(parts[0])
        network = String(parts[1])
        contentFormat = String(parts[2])
        additionalInfo = String(parts[3])
    }

    public var description: String {
        "\(transport):\(network):\(contentFormat):\(additionalInfo)"
    }
}

/// ConnectionManager's `GetProtocolInfo`, the request and its reply.
public enum GetProtocolInfo {
    static let serviceType = "urn:schemas-upnp-org:service:ConnectionManager:1"
    static let action = "GetProtocolInfo"

    /// The fields besides the body that a SOAP request needs.
    static var fields: [(String, String)] {
        [
            ("Content-Type", "text/xml; charset=\"utf-8\""),
            ("SOAPACTION", "\"\(serviceType)#\(action)\""),
        ]
    }

    static var body: [UInt8] {
        Array(
            ("<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\""
                + " s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
                + "<s:Body><u:\(action) xmlns:u=\"\(serviceType)\"/></s:Body></s:Envelope>").utf8)
    }

    /// The sink list in a reply: what the renderer plays. Entries that aren't four parts are
    /// left out, and the count past `ProtocolInfo.entryCap` too.
    public static func sink(_ reply: [UInt8]) throws(DescriptionProblem) -> [ProtocolInfo] {
        let envelope: XMLTree
        do throws(XMLProblem) {
            envelope = try XMLTree.parse(reply)
        } catch {
            throw .unreadable("\(error)")
        }
        guard envelope.name == "Envelope",
            let response = envelope.child("Body")?.child("\(action)Response"),
            let sink = response.child("Sink")
        else { throw .unreadable("it isn't a \(action) response") }
        return sink.text.split(separator: ",").prefix(ProtocolInfo.entryCap).compactMap {
            ProtocolInfo($0.drop { $0.isWhitespace })
        }
    }
}
