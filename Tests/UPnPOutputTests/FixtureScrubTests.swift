import Foundation
import Testing

private let names = [
    "denon-avtransport-scpd.xml", "denon-description.xml", "denon-protocolinfo.xml",
    "sonos-avtransport-scpd.xml", "sonos-description.xml", "sonos-protocolinfo.xml", "ssdp.txt",
]

private func matches(_ pattern: String, in text: String) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern)
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        String(text[Range($0.range, in: text)!])
    }
}

/// The captures came from the owner's network: every identifier in them must be a made-up one,
/// whatever else changes in them.
@Test func theCapturesHoldOnlyMadeUpIdentifiers() throws {
    for name in names {
        let text = try captured(name)
        for address in try matches(#"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#, in: text) {
            // The Sonos's hardware version is a dotted quad too.
            #expect(address.hasPrefix("192.0.2.") || address == "1.38.1.10", "\(name): \(address)")
        }
        for mac in try matches(#"\b([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"#, in: text) {
            #expect(
                mac.uppercased().hasPrefix("00:00:5E:00:53") || mac.hasPrefix("00-00-5E-00-53"),
                "\(name): \(mac)")
        }
        for uuid in try matches(
            #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
            in: text)
        {
            #expect(uuid.hasPrefix("00000000-0000-4000-8000-"), "\(name): \(uuid)")
        }
        for household in try matches(#"Sonos_[A-Za-z0-9]+"#, in: text) {
            #expect(household.dropFirst(6).allSatisfy { $0 == "0" }, "\(name): \(household)")
        }
        for line in text.split(separator: "\r\n") where line.hasPrefix("VERSIONS.UPNP.HEOS.COM") {
            #expect(line.contains("100000001"), "\(name): \(line)")
        }
        for room in try matches(#"<roomName>[^<]*</roomName>"#, in: text) {
            #expect(room == "<roomName>Test Room</roomName>", "\(name): \(room)")
        }
    }
}
