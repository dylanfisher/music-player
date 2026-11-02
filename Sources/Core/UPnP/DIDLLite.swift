/// A track's DIDL-Lite metadata, which `SetAVTransportURI` carries so the renderer can show it
/// and knows the stream's type before it fetches it (ADR 0041). The tags are the file's own
/// text: each is escaped, cut to `tagCap` characters and kept to one line.
package struct DIDLTrack: Equatable, Sendable {
    package var title: String?
    package var artist: String?
    package var album: String?
    /// The renderer's own sink entry the stream matches, such as `http-get:*:audio/flac:*`.
    package var protocolInfo: String
    package var durationSeconds: Double
    package var sizeBytes: Int
    package var sampleRateHz: Int
    /// Nil for a lossy codec.
    package var bitsPerSample: Int?
    package var channels: Int

    package init(
        title: String?, artist: String?, album: String?, protocolInfo: String,
        durationSeconds: Double, sizeBytes: Int, sampleRateHz: Int, bitsPerSample: Int?,
        channels: Int
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.protocolInfo = protocolInfo
        self.durationSeconds = durationSeconds
        self.sizeBytes = sizeBytes
        self.sampleRateHz = sampleRateHz
        self.bitsPerSample = bitsPerSample
        self.channels = channels
    }

    /// Longest tag kept.
    static let tagCap = 512

    /// The document for the stream at `url`.
    package func document(url: String) -> String {
        func element(_ name: String, _ text: String?) -> String {
            guard let text, !text.isEmpty else { return "" }
            let line = String(
                text.prefix(Self.tagCap).map { $0.isNewline ? " " : $0 })
            return xmlElement(name, line)
        }
        var attributes = [
            ("protocolInfo", protocolInfo), ("duration", didlDuration(durationSeconds)),
            ("size", "\(sizeBytes)"), ("sampleFrequency", "\(sampleRateHz)"),
            ("nrAudioChannels", "\(channels)"),
        ]
        if let bitsPerSample { attributes.append(("bitsPerSample", "\(bitsPerSample)")) }
        let res = attributes.map { " \($0.0)=\"\(xmlEscaped($0.1))\"" }.joined()
        return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\""
            + " xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
            + " xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
            + "<item id=\"1\" parentID=\"0\" restricted=\"1\">"
            + element("dc:title", title ?? "") + element("dc:creator", artist)
            + element("upnp:artist", artist) + element("upnp:album", album)
            + "<upnp:class>object.item.audioItem.musicTrack</upnp:class>"
            + "<res\(res)>\(xmlEscaped(url))</res></item></DIDL-Lite>"
    }
}

/// `H:MM:SS.FFF`, the form DIDL-Lite's `duration` takes.
private func didlDuration(_ seconds: Double) -> String {
    let millis = Int((min(max(seconds, 0), upnpTimeCapSeconds) * 1000).rounded())
    let fraction = millis % 1000
    let padded = String(repeating: "0", count: 3 - String(fraction).count) + String(fraction)
    return upnpTime(Double(millis / 1000)) + "." + padded
}
