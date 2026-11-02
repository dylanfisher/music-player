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
