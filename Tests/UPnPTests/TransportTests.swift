import Foundation
import Testing

@testable import LocalNetwork
@testable import UPnP

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

private func response(_ action: String, _ body: String) -> String {
    """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
    <u:\(action)Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">\(body)\
    </u:\(action)Response></s:Body></s:Envelope>
    """
}

@Test func anActionsArgumentsAreEscapedSoTheyCantChangeTheRequest() throws {
    let action = AVTransport.setURI(
        "http://192.0.2.1:9/abc?x=1&y=2", metadata: "<DIDL-Lite>\u{0}</DIDL-Lite>")
    let body = String(decoding: action.body, as: UTF8.self)
    #expect(
        body.contains(
            "<u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"
                + "<InstanceID>0</InstanceID><CurrentURI>http://192.0.2.1:9/abc?x=1&amp;y=2"
                + "</CurrentURI><CurrentURIMetaData>&lt;DIDL-Lite&gt;&lt;/DIDL-Lite&gt;"
                + "</CurrentURIMetaData></u:SetAVTransportURI>"))
    #expect(
        action.fields.map(\.1).contains(
            "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\""))
    // The request is well-formed XML that reads back as the arguments it was given.
    let tree = try XMLTree.parse(action.body)
    let sent = try #require(tree.child("Body")?.child("SetAVTransportURI"))
    #expect(sent.value("CurrentURIMetaData") == "<DIDL-Lite></DIDL-Lite>")
}

@Test func whitespaceInAnArgumentReadsBackAsSent() throws {
    let value = "line one\r\nline two\r\tend\n"
    let action = SOAPAction("urn:x", "Act", [("Text", value)])
    #expect(try xmlLeaves(action.body).first { $0.name == "Text" }?.text == value)
}

@Test func aSeekGoesToWholeSecondsAsRelativeTime() {
    let body = String(decoding: AVTransport.seek(toSeconds: 3725.9).body, as: UTF8.self)
    #expect(body.contains("<Unit>REL_TIME</Unit><Target>1:02:05</Target>"))
    #expect(upnpTime(-4) == "0:00:00")
    #expect(upnpTime(59) == "0:00:59")
}

@Test func timesAreReadOnlyInTheirOneForm() {
    #expect(upnpSeconds("0:03:12") == 192)
    #expect(upnpSeconds("00:03:12.500") == 192.5)
    #expect(upnpSeconds("12:00:00") == 43_200)
    for bad in [
        "NOT_IMPLEMENTED", "", "3:12", "0:60:00", "0:00:60", "0:0:1", "-1:00:00", "1:00:00.",
        "0:00:01.1234567890", "1000000:00:00", "999999:59:59", "٣:00:00", "0:00:01,5",
        "+1:00:00",
    ] {
        #expect(upnpSeconds(bad) == nil, "\(bad)")
    }
}

@Test func transportAndPositionRepliesAreRead() throws {
    let transport = try TransportInfo(
        AVTransport.transportInfo.response(
            bytes(
                response(
                    "GetTransportInfo",
                    "<CurrentTransportState>PAUSED_PLAYBACK</CurrentTransportState>"
                        + "<CurrentTransportStatus>OK</CurrentTransportStatus>"))))
    #expect(transport.state == .paused && transport.isOK)
    let odd = try TransportInfo(
        AVTransport.transportInfo.response(
            bytes(
                response(
                    "GetTransportInfo",
                    "<CurrentTransportState>CUSTOM\tSTATE</CurrentTransportState>"
                        + "<CurrentTransportStatus>ERROR_OCCURRED</CurrentTransportStatus>"))))
    #expect(odd.state == .other("CUSTOM\\u{9}STATE") && !odd.isOK)
    #expect(throws: DescriptionProblem.self) {
        try TransportInfo(
            AVTransport.transportInfo.response(bytes(response("GetTransportInfo", ""))))
    }

    let position = PositionInfo(
        try AVTransport.positionInfo.response(
            bytes(
                response(
                    "GetPositionInfo",
                    "<Track>1</Track><TrackDuration>0:04:00</TrackDuration>"
                        + "<TrackURI>http://192.0.2.1:9/t</TrackURI><RelTime>0:01:30</RelTime>"
                        + "<AbsTime>NOT_IMPLEMENTED</AbsTime>"))))
    #expect(position.trackURI == "http://192.0.2.1:9/t")
    #expect(position.seconds == 90 && position.durationSeconds == 240)
    let empty = PositionInfo(
        try AVTransport.positionInfo.response(
            bytes(response("GetPositionInfo", "<RelTime>NOT_IMPLEMENTED</RelTime>"))))
    #expect(empty.trackURI == "" && empty.seconds == nil && empty.durationSeconds == nil)
    // A reply to another action isn't taken for this one.
    #expect(throws: DescriptionProblem.self) {
        try AVTransport.positionInfo.response(bytes(response("GetTransportInfo", "")))
    }
}

@Test func aFaultGivesItsUPnPErrorEscaped() throws {
    let raw = bytes(
        "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/xml\r\n\r\n"
            + """
            <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
            <s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>
            <detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>714</errorCode>
            <errorDescription>Illegal\tMIME-type</errorDescription></UPnPError></detail>
            </s:Fault></s:Body></s:Envelope>
            """)
    let fault = try #require(UPnPFault(raw))
    #expect(fault.code == 714 && fault.text == "Illegal\\u{9}MIME-type")
    #expect(
        "\(SOAPProblem.fault(action: "SetAVTransportURI", status: 500, fault))"
            == "SetAVTransportURI failed with status 500: UPnP error 714 (Illegal\\u{9}MIME-type)")
    #expect(UPnPFault(bytes("HTTP/1.1 500 x\r\n\r\nnot xml")) == nil)
    #expect(UPnPFault(bytes("HTTP/1.1 500 x\r\n\r\n<!DOCTYPE x><x/>")) == nil)
}

@Test func aServiceDescriptionGivesItsActionNames() throws {
    let scpd = """
        <?xml version="1.0"?><scpd xmlns="urn:schemas-upnp-org:service-1-0"><actionList>
        <action><name>Play</name></action><action><name>SetNextAVTransportURI</name></action>
        <action/></actionList><serviceStateTable/></scpd>
        """
    #expect(try serviceActions(bytes(scpd)) == ["Play", "SetNextAVTransportURI"])
    let many =
        "<scpd><actionList>"
        + (0..<300).map { "<action><name>A\($0)</name></action>" }.joined()
        + "</actionList></scpd>"
    #expect(try serviceActions(bytes(many)).count == serviceActionCap)
    for bad in ["<root/>", "<scpd/>", "<!DOCTYPE scpd><scpd><actionList/></scpd>"] {
        #expect(throws: DescriptionProblem.self) { try serviceActions(bytes(bad)) }
    }
}

private let track = DIDLTrack(
    title: "A & B <live>\n\"take\" 2", artist: "Ar\u{1}tist", album: nil,
    protocolInfo: "http-get:*:audio/flac:*", durationSeconds: 192.0005, sizeBytes: 12_345,
    sampleRateHz: 96_000, bitsPerSample: 24, channels: 2)

@Test func didlLiteEscapesTheTagsAndDescribesTheStream() throws {
    let document = track.document(url: "http://192.0.2.1:9/abc")
    #expect(document.contains("<dc:title>A &amp; B &lt;live&gt; &quot;take&quot; 2</dc:title>"))
    #expect(document.contains("<upnp:artist>Artist</upnp:artist>"))
    #expect(!document.contains("upnp:album"))
    #expect(
        document.contains(
            "<res protocolInfo=\"http-get:*:audio/flac:*\" duration=\"0:03:12.001\""
                + " size=\"12345\" sampleFrequency=\"96000\" nrAudioChannels=\"2\""
                + " bitsPerSample=\"24\">http://192.0.2.1:9/abc</res>"))
    // It parses as XML, with the title as the file has it on one line.
    let tree = try XMLTree.parse(Array(document.utf8))
    #expect(tree.child("item")?.value("title") == "A & B <live> \"take\" 2")
}

@Test func aLongTagIsCut() {
    var long = track
    long.title = String(repeating: "x", count: 5000)
    let document = long.document(url: "u")
    #expect(
        document.contains("<dc:title>\(String(repeating: "x", count: DIDLTrack.tagCap))</dc:title>")
    )
}
