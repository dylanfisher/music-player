import Foundation
import Testing

@testable import UPnP

/// A description shaped like a HEOS-era Denon's: a root device with the renderer nested in it.
func descriptionXML(
    name: String = "Living Room",
    controlURL: String = "/upnp/control/renderer_dvc/ConnectionManager",
    renderer: String = "urn:schemas-upnp-org:device:MediaRenderer:1"
) -> String {
    """
    <?xml version="1.0" encoding="utf-8"?>
    <root xmlns="urn:schemas-upnp-org:device-1-0">
      <specVersion><major>1</major><minor>0</minor></specVersion>
      <device>
        <deviceType>urn:schemas-denon-com:device:AiosDevice:1</deviceType>
        <friendlyName>\(name)</friendlyName>
        <manufacturer>Denon</manufacturer>
        <modelName>Denon AVR-X1800H</modelName>
        <UDN>uuid:root-1</UDN>
        <deviceList>
          <device>
            <deviceType>\(renderer)</deviceType>
            <friendlyName>\(name)</friendlyName>
            <manufacturer>Denon</manufacturer>
            <modelName>Denon AVR-X1800H</modelName>
            <UDN>uuid:renderer-1</UDN>
            <serviceList>
              <service>
                <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
                <controlURL>/upnp/control/renderer_dvc/AVTransport</controlURL>
              </service>
              <service>
                <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
                <controlURL>\(controlURL)</controlURL>
              </service>
            </serviceList>
          </device>
        </deviceList>
      </device>
    </root>
    """
}

func sinkXML(_ sink: String) -> String {
    """
    <?xml version="1.0"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
    <u:GetProtocolInfoResponse xmlns:u="urn:schemas-upnp-org:service:ConnectionManager:1">
    <Source></Source><Sink>\(sink)</Sink></u:GetProtocolInfoResponse></s:Body></s:Envelope>
    """
}

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

private func refusal(_ text: String) -> DescriptionProblem? {
    do {
        _ = try DeviceDescription(bytes(text))
        return nil
    } catch {
        return error
    }
}

@Test func aDescriptionGivesItsRendererAndServices() throws {
    let description = try DeviceDescription(bytes(descriptionXML()))
    #expect(description.devices.map(\.udn) == ["uuid:root-1", "uuid:renderer-1"])
    let renderer = try #require(description.device(ofType: RendererDiscovery.mediaRenderer))
    #expect(renderer.name == "Living Room")
    #expect(renderer.manufacturer == "Denon")
    #expect(renderer.model == "Denon AVR-X1800H")
    #expect(
        renderer.service(ofType: GetProtocolInfo.serviceType)?.controlURL
            == "/upnp/control/renderer_dvc/ConnectionManager")
}

@Test func aRenderersNameIsEscapedAndCut() throws {
    let name = "Den&#x9B;2Jon&#10;Fake line" + String(repeating: "x", count: 400)
    let renderer = try #require(
        try DeviceDescription(bytes(descriptionXML(name: name))).devices.last)
    #expect(renderer.name.hasPrefix("Den\\u{9B}2Jon\\u{A}Fake line"))
    #expect(!renderer.name.contains("\n"))
    #expect(renderer.name.count < DeviceDescription.nameCap + 20)
}

@Test func entitiesAndDTDsAreRefusedBeforeParsing() {
    let hostile = [
        // XXE: an external entity naming a local file and a URL.
        """
        <?xml version="1.0"?><!DOCTYPE root [<!ENTITY x SYSTEM "file:///etc/passwd">]>
        <root><device><friendlyName>&x;</friendlyName></device></root>
        """,
        """
        <?xml version="1.0"?><!DOCTYPE root SYSTEM "http://127.0.0.1:9/evil.dtd"><root/>
        """,
        // An entity expansion, ten deep.
        "<?xml version=\"1.0\"?><!doctype lolz [<!ENTITY a \"aaaaaaaaaa\">"
            + (1..<10).map { "<!ENTITY b\($0) \"&b\($0 - 1);&b\($0 - 1);\">" }.joined()
            + "]><root><device>&b9;</device></root>",
        "<root><!ENTITY x \"y\"><device/></root>",
    ]
    for text in hostile {
        #expect(refusal(text) == .unreadable("it declares a DTD or entities"))
    }
}

@Test func oversizeDeepAndMalformedDescriptionsAreRefused() {
    let big = "<root>" + String(repeating: " ", count: 1024 * 1024) + "</root>"
    #expect(refusal(big) == .unreadable("\(big.utf8.count) bytes is over the 1048576-byte cap"))
    let deep = String(repeating: "<a>", count: 40) + String(repeating: "</a>", count: 40)
    #expect(refusal(deep) == .unreadable("it nests deeper than 32"))
    let wide = "<root>" + String(repeating: "<a/>", count: 10_001) + "</root>"
    #expect(refusal(wide) == .unreadable("it has over 10000 elements"))
    #expect(refusal("<root><device>") != nil)
    #expect(refusal("not xml") != nil)
    #expect(refusal("") != nil)
    #expect(refusal("<root><nodevice/></root>") == .unreadable("it has no root device"))
    #expect(refusal("<html><device/></html>") == .unreadable("it has no root device"))
}

@Test func theSinkListGivesEachFormat() throws {
    let formats = try GetProtocolInfo.sink(
        bytes(
            sinkXML(
                "http-get:*:audio/flac:*, http-get:*:audio/x-flac:*,bad,http-get:*:audio/L16;rate=44100;channels=2:DLNA.ORG_PN=LPCM"
            )))
    #expect(
        formats.map(\.description) == [
            "http-get:*:audio/flac:*", "http-get:*:audio/x-flac:*",
            "http-get:*:audio/L16;rate=44100;channels=2:DLNA.ORG_PN=LPCM",
        ])
    let many = (0..<2000).map { "http-get:*:audio/x\($0):*" }.joined(separator: ",")
    #expect(try GetProtocolInfo.sink(bytes(sinkXML(many))).count == ProtocolInfo.entryCap)
}

@Test func aFaultOrAHostileReplyIsRefused() {
    let fault = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault>
        <faultcode>s:Client</faultcode></s:Fault></s:Body></s:Envelope>
        """
    let replies = [
        fault, "<!DOCTYPE x [<!ENTITY e SYSTEM \"file:///etc/passwd\">]>" + sinkXML("&e;"),
        "<Envelope><Body/></Envelope>", "garbage",
    ]
    for reply in replies {
        #expect(throws: DescriptionProblem.self) { try GetProtocolInfo.sink(bytes(reply)) }
    }
}

@Test func theRequestIsTheSOAPActionItNames() {
    let body = String(decoding: GetProtocolInfo.body, as: UTF8.self)
    #expect(
        body.contains(
            "<u:GetProtocolInfo xmlns:u=\"urn:schemas-upnp-org:service:ConnectionManager:1\"/>"))
    #expect(
        GetProtocolInfo.fields.map(\.1).contains(
            "\"urn:schemas-upnp-org:service:ConnectionManager:1#GetProtocolInfo\""))
}

@Test func onlyUTF8XMLIsRead() {
    let good = descriptionXML()
    let start = "it has a NUL or a BOM, or doesn't start with <"
    let utf16: [UInt8] =
        [0xFF, 0xFE]
        + good.utf16.flatMap { (unit: UInt16) -> [UInt8] in
            [UInt8(unit & 0xFF), UInt8(unit >> 8)]
        }
    let refused: [([UInt8], String)] = [
        ([0xEF, 0xBB, 0xBF] + bytes(good), start), (utf16, start), (bytes(" " + good), start),
        (bytes(good.replacingOccurrences(of: "Living", with: "Liv\u{0}ing")), start),
        (
            bytes(good.replacingOccurrences(of: "utf-8", with: "ISO-8859-1")),
            "it declares the encoding ISO-8859-1"
        ),
        (
            bytes(good.replacingOccurrences(of: "encoding=\"utf-8\"", with: "encoding='UTF-16'")),
            "it declares the encoding UTF-16"
        ),
    ]
    for (input, why) in refused {
        var problem: DescriptionProblem?
        do { _ = try DeviceDescription(input) } catch { problem = error }
        #expect(problem == .unreadable("it isn't UTF-8 XML: \(why)"))
    }
    #expect(refusal(good.replacingOccurrences(of: "utf-8", with: "UTF-8")) == nil)
}
