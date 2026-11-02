import LocalNetwork
import Receiver
import UPnP

/// The receiver's status lines, split at each carriage return as the connection splits them.
let receiverLine = FuzzTarget(
    name: "receiver-line",
    summary: "a Denon receiver's status lines, each read as the connection reads it",
    seedFormats: [],
    tokens: ["PW", "MV", "MU", "SI", "MS", "MVMAX ", "\r", "5"]
        + ReceiverSoundMode.allCases.map(\.rawValue),
    madeSeeds: { _, _ in
        [
            "PWON\rMV805\rMUOFF\rSICD\rMSPURE DIRECT\rCVFL 50\r",
            "MV00\rMV99\rMV985\rMVMAX 98\rSIHEOS MUSIC\rMSQUICK1\rZ2ON\r",
            "PWSTANDBY\rMUON\rSISAT/CBL\rMSDOLBY AUDIO-DD+DSUR\r",
        ].map { Array($0.utf8) }
    },
    prepare: { _ in
        { input in
            var followed = false
            for line in input.split(separator: 0x0D, omittingEmptySubsequences: false) {
                guard case .event(let event) = ReceiverLine(line) else { continue }
                followed = true
                switch event {
                case .volume(let volume):
                    precondition((-80...18).contains(volume.decibels), "volume \(volume.decibels)")
                case .soundMode(let name):
                    precondition(
                        !name.isEmpty && name.count <= 25
                            && name.unicodeScalars.allSatisfy {
                                $0.value >= 0x20 && $0.value < 0x7F
                            },
                        "sound mode \(name.debugDescription)")
                case .power, .mute, .input:
                    break
                }
            }
            return followed
        }
    })

/// A UPnP device description, as a renderer serves it.
let deviceDescription = FuzzTarget(
    name: "device-description",
    summary: "a UPnP device description, its devices and their escaped names",
    seedFormats: [], tokens: ["<!", "&#x9B;", "<device>", "</device>", "&amp;"],
    madeSeeds: { _, _ in
        [
            """
            <?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device>
            <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
            <friendlyName>Living Room&#x9B;</friendlyName><manufacturer>Denon</manufacturer>
            <modelName>AVR-X1800H</modelName><UDN>uuid:1</UDN><serviceList><service>
            <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
            <controlURL>/ctl/cm</controlURL></service></serviceList><deviceList><device>
            <deviceType>x</deviceType><friendlyName>Zone 2</friendlyName></device></deviceList>
            </device></root>
            """
        ].map { Array($0.utf8) }
    },
    prepare: { _ in
        { input in
            let description: DeviceDescription
            do {
                description = try DeviceDescription(input)
            } catch {
                return false
            }
            for device in description.devices {
                for text in [device.name, device.manufacturer, device.model] {
                    precondition(
                        !text.unicodeScalars.contains {
                            $0.value < 0x20 || (0x7F...0x9F).contains($0.value)
                        }, "a control character in \(text.debugDescription)")
                }
            }
            return true
        }
    })

/// A ConnectionManager's `GetProtocolInfo` reply.
let soapReply = FuzzTarget(
    name: "soap-reply",
    summary: "a GetProtocolInfo SOAP reply and its sink list",
    seedFormats: [], tokens: ["http-get:*:", "audio/flac", ":*,", "<Sink>", "</Sink>", "<!"],
    madeSeeds: { _, _ in
        [
            """
            <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
            <s:Body><u:GetProtocolInfoResponse xmlns:u="urn:schemas-upnp-org:service:ConnectionManager:1">
            <Source></Source><Sink>http-get:*:audio/flac:*,http-get:*:audio/L16;rate=44100:DLNA.ORG_PN=LPCM</Sink>
            </u:GetProtocolInfoResponse></s:Body></s:Envelope>
            """
        ].map { Array($0.utf8) }
    },
    prepare: { _ in
        { input in
            let formats: [ProtocolInfo]
            do {
                formats = try GetProtocolInfo.sink(input)
            } catch {
                return false
            }
            precondition(formats.count <= 1024, "\(formats.count) formats")
            for format in formats {
                precondition(
                    format.description.split(separator: ":", omittingEmptySubsequences: false).count
                        >= 4, "\(format) isn't four parts")
            }
            return true
        }
    })

/// AVTransport's `GetTransportInfo` and `GetPositionInfo` replies, which the UPnP output polls.
let avTransportReply = FuzzTarget(
    name: "avtransport-reply",
    summary: "GetTransportInfo and GetPositionInfo replies, their states and times",
    seedFormats: [],
    tokens: [
        "NOT_IMPLEMENTED", "TRANSITIONING ", "99:59:59.999", ":", ".", "<RelTime>",
        "<TrackDuration>", "Response",
    ],
    madeSeeds: { _, _ in
        ["Transport", "Position"].map { kind in
            Array(
                ("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body>"
                    + "<u:Get\(kind)InfoResponse"
                    + " xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"
                    + "<CurrentTransportState>PLAYING</CurrentTransportState>"
                    + "<CurrentTransportStatus>OK</CurrentTransportStatus>"
                    + "<TrackDuration>0:04:00</TrackDuration><TrackURI>http://192.0.2.1/t</TrackURI>"
                    + "<RelTime>0:01:30.5</RelTime></u:Get\(kind)InfoResponse></s:Body>"
                    + "</s:Envelope>").utf8)
        }
    },
    prepare: { _ in
        { input in
            var read = false
            if let info = try? AVTransport.transportInfo(fromReply: input) {
                read = true
                if case .other(let state) = info.state {
                    precondition(
                        !state.unicodeScalars.contains { $0.value < 0x20 },
                        "a control character in \(state.debugDescription)")
                }
            }
            if let position = try? AVTransport.positionInfo(fromReply: input) {
                read = true
                for seconds in [position.seconds, position.durationSeconds].compactMap({ $0 }) {
                    precondition(
                        seconds >= 0 && seconds <= 1_000_000 && seconds.isFinite,
                        "a time of \(seconds)")
                }
            }
            return read
        }
    })

/// A UPnP service description, whose action list says whether a renderer is gapless.
let serviceDescription = FuzzTarget(
    name: "service-description",
    summary: "a UPnP service description's action names",
    seedFormats: [], tokens: ["<action>", "</action>", "<name>", "</name>", "<actionList>"],
    madeSeeds: { _, _ in
        [
            """
            <?xml version="1.0"?><scpd xmlns="urn:schemas-upnp-org:service-1-0"><actionList>
            <action><name>Play</name></action><action><name>SetNextAVTransportURI</name>
            <argumentList><argument><name>NextURI</name></argument></argumentList></action>
            </actionList></scpd>
            """
        ].map { Array($0.utf8) }
    },
    prepare: { _ in
        { input in
            do {
                let actions = try serviceActions(input)
                precondition(actions.count <= 256, "\(actions.count) actions")
                return true
            } catch {
                return false
            }
        }
    })

/// A request to the server the UPnP output streams from: its head and its `Range`.
let httpRequest = FuzzTarget(
    name: "http-request",
    summary: "a request head to the track server and the bytes its Range picks",
    seedFormats: [],
    tokens: ["\r\n", "Range: bytes=", "-", ",", "Host: 127.0.0.1:8080", "GET /", "HEAD /"],
    madeSeeds: { _, _ in
        let path = "/" + String(repeating: "0", count: 32)
        return [
            "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nRange: bytes=0-99\r\n\r\n",
            "HEAD \(path) HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nRange: bytes=-5\r\n\r\n",
            "GET \(path) HTTP/1.0\r\nHost: 127.0.0.1:8080\r\n\r\n",
        ].map { Array($0.utf8) }
    },
    prepare: { _ in
        { input in
            let size: UInt64 = 1000
            guard
                let (status, bytes) = answer(
                    toRequest: input, authority: "127.0.0.1:8080", fileSize: size)
            else { return false }
            switch status {
            case 200:
                precondition(
                    bytes == 0...(size - 1), "a whole file of \(String(describing: bytes))")
            case 206:
                let range = bytes!
                precondition(range.upperBound < size, "a range past the file: \(range)")
            default: precondition(bytes == nil, "status \(status) with bytes")
            }
            return status == 200 || status == 206
        }
    })

/// A track's tags as the UPnP output sends them: DIDL-Lite inside a SetAVTransportURI request.
/// Both must read back as the text they were given, so no tag can change the XML.
let didlLite = FuzzTarget(
    name: "didl-lite",
    summary: "a track's tags in DIDL-Lite in a SOAP request, read back as written",
    seedFormats: [], tokens: ["&", "<", "]]>", "\"", "\r\n", "\u{0}", "\u{2028}", "\u{FFFE}"],
    madeSeeds: { _, _ in
        ["A & B <live>\0Artist\r\nName\0\"Album\" ]]>", "\u{1}\u{FFFF}\0\0", "x\0y"].map {
            Array($0.utf8)
        }
    },
    prepare: { _ in
        { input in
            // Tags come separated by NULs, so one field alone is no track.
            guard input.count <= 4096, input.contains(0) else { return false }
            let fields = input.split(separator: 0, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            let tags = (0..<3).map { $0 < fields.count ? fields[$0] : "" }
            let track = DIDLTrack(
                title: tags[0], artist: tags[1], album: tags[2],
                protocolInfo: "http-get:*:audio/flac:*", durationSeconds: 1, sizeBytes: 1,
                sampleRateHz: 44_100, bitsPerSample: 16, channels: 2)
            let document = track.document(
                url: "http://192.0.2.1:1/" + String(repeating: "0", count: 32))
            let request = AVTransport.setURI("u", metadata: document)
            guard let sent = try? AVTransport.metadata(inSetURIRequest: request.body) else {
                preconditionFailure("the request doesn't parse")
            }
            precondition(sent == document, "the metadata didn't survive the request")
            guard let read = try? DIDLTrack.tags(in: document) else {
                preconditionFailure("the DIDL-Lite doesn't parse")
            }
            precondition(
                read == tags.map(didlText), "the tags read back changed: \(tags.debugDescription)")
            return true
        }
    })

/// What a tag should read back as from DIDL-Lite: cut to the cap and to one line, without the
/// characters XML 1.0 can't hold. An oracle apart from the writer's own code.
private func didlText(_ tag: String) -> String {
    let line = String(tag.prefix(512).map { $0.isNewline ? " " : $0 })
    var kept = String.UnicodeScalarView()
    for scalar in line.unicodeScalars {
        let value = scalar.value
        if value == 0x9 || value == 0xA || value == 0xD
            || (value >= 0x20 && value != 0xFEFF && value != 0xFFFE && value != 0xFFFF)
        {
            kept.append(scalar)
        }
    }
    return String(kept)
}

/// A chunked HTTP body, as a renderer may send a description or a SOAP reply.
let chunkedBody = FuzzTarget(
    name: "chunked-body", summary: "a chunked HTTP body, decoded under a cap",
    seedFormats: [], tokens: ["\r\n", "0\r\n\r\n", ";ext=1", "-1", "ffffffff"],
    madeSeeds: { _, _ in
        [
            "5\r\nhello\r\n0\r\n\r\n", "3;x=y\r\nabc\r\n0\r\nA: b\r\n\r\n",
            "-1\r\nab\r\n0\r\n\r\n", "1\r\na\r\n1\r\nb\r\n0\r\n\r\n",
        ].map { Array($0.utf8) }
    },
    prepare: { _ in
        { input in
            let cap = 64
            switch decodeChunked(input[...], cap: cap) {
            case .done(let body):
                precondition(body.count <= cap, "\(body.count) bytes past the cap")
                return true
            case .incomplete, .tooLarge, .malformed:
                return false
            }
        }
    })
