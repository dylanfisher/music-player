import LocalNetwork

/// One action of a UPnP service, as a control point posts it (ADR 0041). Argument values are
/// escaped, so a tag or a URL can't change the request's XML.
package struct SOAPAction: Sendable {
    let serviceType: String
    let name: String
    let arguments: [(name: String, value: String)]

    init(
        _ serviceType: String, _ name: String, _ arguments: [(name: String, value: String)] = []
    ) {
        self.serviceType = serviceType
        self.name = name
        self.arguments = arguments
    }

    /// The fields besides the body that the request needs.
    var fields: [(String, String)] {
        [
            ("Content-Type", "text/xml; charset=\"utf-8\""),
            ("SOAPACTION", "\"\(serviceType)#\(name)\""),
        ]
    }

    package var body: [UInt8] {
        let arguments = self.arguments.map { xmlElement($0.name, $0.value) }
        let action =
            arguments.isEmpty
            ? "<u:\(name) xmlns:u=\"\(serviceType)\"/>"
            : "<u:\(name) xmlns:u=\"\(serviceType)\">\(arguments.joined())</u:\(name)>"
        return Array(
            ("<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\""
                + " s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
                + "<s:Body>\(action)</s:Body></s:Envelope>").utf8)
    }

    /// The reply's `<u:NameResponse>`, which holds the out arguments.
    func response(_ reply: [UInt8]) throws(DescriptionProblem) -> XMLTree {
        let envelope: XMLTree
        do throws(XMLProblem) {
            envelope = try XMLTree.parse(reply)
        } catch {
            throw .unreadable("\(error)")
        }
        guard envelope.name == "Envelope",
            let response = envelope.child("Body")?.child("\(name)Response")
        else { throw .unreadable("it isn't a \(name) response") }
        return response
    }

    /// Posts the action to `control`. A refused connection, a failed one and a deadline are
    /// `unreachable`; a status 500 is the renderer's fault, with its UPnP error when it says one.
    func call(_ control: LocalURL, timeoutSeconds: Double) async throws(SOAPProblem)
        -> XMLTree
    {
        let reply: [UInt8]
        do throws(LocalNetworkError) {
            reply = try await LocalHTTPClient.post(
                control, fields: fields, body: body, timeoutSeconds: timeoutSeconds,
                keepingRefusals: true)
        } catch {
            switch error {
            case .refused, .failed, .timedOut, .cancelled, .system:
                throw .unreachable(action: name, error)
            case .statusReply(let status, let raw):
                throw .fault(action: name, status: status, UPnPFault(raw))
            case .status(let status):
                throw .fault(action: name, status: status, nil)
            case .tooLarge, .malformed:
                throw .unreadable(action: name, "\(error)")
            }
        }
        do throws(DescriptionProblem) {
            return try response(reply)
        } catch {
            throw .unreadable(action: name, "\(error)")
        }
    }
}

/// Why an action didn't do what it asked.
package enum SOAPProblem: Error, Equatable, CustomStringConvertible {
    /// Nothing answered in time, or the connection failed: the renderer may be gone.
    case unreachable(action: String, LocalNetworkError)
    /// The renderer answered with an error status, and the UPnP error it gave, if it gave one.
    case fault(action: String, status: Int, UPnPFault?)
    case unreadable(action: String, String)

    package var description: String {
        switch self {
        case .unreachable(let action, let error): "\(action) got no answer: \(error)"
        case .fault(let action, let status, let fault):
            "\(action) failed with status \(status)" + (fault.map { ": \($0)" } ?? "")
        case .unreadable(let action, let why): "\(action)'s reply was ignored: \(why)"
        }
    }
}

/// The `UPnPError` in a SOAP fault: its code, such as 714 for a MIME type the renderer refuses,
/// and its text, escaped as display text.
package struct UPnPFault: Equatable, Sendable, CustomStringConvertible {
    let code: Int?
    let text: String?

    /// Reads the fault from a reply's head and body; nil when the body isn't one.
    init?(_ raw: [UInt8]) {
        // A body that isn't XML isn't a fault, the nil documented above.
        guard let end = raw.firstRange(of: Array("\r\n\r\n".utf8)),
            let envelope = try? XMLTree.parse(Array(raw[end.upperBound...])),
            let detail = envelope.child("Body")?.child("Fault")?.child("detail")?.child(
                "UPnPError")
        else { return nil }
        code = detail.value("errorCode").flatMap { Int($0) }
        text = detail.value("errorDescription").map { shown($0) }
    }

    package var description: String {
        "UPnP error \(code.map(String.init) ?? "with no code")"
            + (text.map { " (\($0))" } ?? "")
    }
}

/// An element holding `text`, escaped.
func xmlElement(_ name: String, _ text: String) -> String {
    "<\(name)>\(xmlEscaped(text))</\(name)>"
}

/// `text` with the five characters XML gives meaning escaped, and the characters XML 1.0 can't
/// hold dropped, so a file's tags can't break or extend the document they're put in; so is a
/// byte order mark, which `XMLParser` drops from text and so wouldn't read back. Tab, LF
/// and CR go as character references, since a parser turns CR LF into LF and, in an
/// attribute, each of them into a space.
func xmlEscaped(_ text: String) -> String {
    var escaped = ""
    escaped.reserveCapacity(text.utf8.count)
    for scalar in text.unicodeScalars {
        switch scalar {
        case "&": escaped += "&amp;"
        case "<": escaped += "&lt;"
        case ">": escaped += "&gt;"
        case "\"": escaped += "&quot;"
        case "'": escaped += "&apos;"
        case "\t": escaped += "&#9;"
        case "\n": escaped += "&#10;"
        case "\r": escaped += "&#13;"
        default:
            let value = scalar.value
            if value >= 0x20 && value != 0xFEFF && value != 0xFFFE && value != 0xFFFF {
                escaped.unicodeScalars.append(scalar)
            }
        }
    }
    return escaped
}
