import Foundation

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

    /// The content format's MIME type without its parameters, lowercased: `audio/l16` for
    /// `audio/L16;rate=44100;channels=2`.
    package var mimeType: String {
        String(contentFormat.prefix { $0 != ";" }).trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    /// Streams a control point serves over HTTP, as the app does.
    var isHTTP: Bool { transport == "http-get" }
}

extension Renderer {
    /// The renderer's own sink entry for the first of `types` it takes over HTTP; nil when it
    /// takes none of them.
    package func sinkEntry(for types: [String]) -> ProtocolInfo? {
        for type in types {
            if let entry = sinkFormats.first(where: { $0.isHTTP && $0.mimeType == type }) {
                return entry
            }
        }
        return nil
    }

    /// Every audio type the renderer takes over HTTP, once each, for saying what it does take.
    package var httpAudioTypes: [String] {
        var types: [String] = []
        for entry in sinkFormats where entry.isHTTP && entry.mimeType.hasPrefix("audio/") {
            if !types.contains(entry.mimeType) { types.append(entry.mimeType) }
        }
        return types
    }
}

/// ConnectionManager's `GetProtocolInfo`, the request and its reply.
public enum GetProtocolInfo {
    static let serviceType = "urn:schemas-upnp-org:service:ConnectionManager:1"
    static let action = "GetProtocolInfo"

    static var request: SOAPAction { SOAPAction(serviceType, action) }

    /// The sink list in a reply: what the renderer plays. Entries that aren't four parts are
    /// left out, and the count past `ProtocolInfo.entryCap` too.
    public static func sink(_ reply: [UInt8]) throws(DescriptionProblem) -> [ProtocolInfo] {
        guard let sink = try request.response(reply).child("Sink") else {
            throw .unreadable("its reply has no Sink")
        }
        return sink.text.split(separator: ",").prefix(ProtocolInfo.entryCap).compactMap {
            ProtocolInfo($0.drop { $0.isWhitespace })
        }
    }
}
