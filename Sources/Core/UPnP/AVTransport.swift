import LocalNetwork

/// AVTransport's actions for instance 0, the one a renderer plays one stream on, and what its
/// replies say (ADR 0041). Every value a reply holds is the renderer's own text, so each is
/// checked before it's used.
package enum AVTransport {
    static let serviceType = "urn:schemas-upnp-org:service:AVTransport:1"
    package static let setNextURIAction = "SetNextAVTransportURI"

    private static func action(_ name: String, _ arguments: [(name: String, value: String)] = [])
        -> SOAPAction
    {
        SOAPAction(serviceType, name, [("InstanceID", "0")] + arguments)
    }

    package static func setURI(_ uri: String, metadata: String) -> SOAPAction {
        action("SetAVTransportURI", [("CurrentURI", uri), ("CurrentURIMetaData", metadata)])
    }

    /// An empty `uri` clears the next track.
    package static func setNextURI(_ uri: String, metadata: String) -> SOAPAction {
        action(setNextURIAction, [("NextURI", uri), ("NextURIMetaData", metadata)])
    }

    package static var play: SOAPAction { action("Play", [("Speed", "1")]) }
    package static var pause: SOAPAction { action("Pause") }
    package static var stop: SOAPAction { action("Stop") }

    package static func seek(toSeconds seconds: Double) -> SOAPAction {
        action("Seek", [("Unit", "REL_TIME"), ("Target", upnpTime(seconds))])
    }

    static var transportInfo: SOAPAction { action("GetTransportInfo") }
    static var positionInfo: SOAPAction { action("GetPositionInfo") }
}

/// One renderer's AVTransport: its actions, each posted under the client's caps and a
/// deadline, and its replies read as hostile text.
package struct AVTransportControl: Sendable {
    let transport: Renderer.Transport
    let timeoutSeconds: Double

    package init(_ transport: Renderer.Transport, timeoutSeconds: Double) {
        self.transport = transport
        self.timeoutSeconds = timeoutSeconds
    }

    package func send(_ action: SOAPAction) async throws(SOAPProblem) {
        _ = try await action.call(transport.control, timeoutSeconds: timeoutSeconds)
    }

    package func transportInfo() async throws(SOAPProblem) -> TransportInfo {
        let action = AVTransport.transportInfo
        let reply = try await action.call(transport.control, timeoutSeconds: timeoutSeconds)
        do throws(DescriptionProblem) {
            return try TransportInfo(reply)
        } catch {
            throw .unreadable(action: action.name, "\(error)")
        }
    }

    package func positionInfo() async throws(SOAPProblem) -> PositionInfo {
        PositionInfo(
            try await AVTransport.positionInfo.call(
                transport.control, timeoutSeconds: timeoutSeconds))
    }

    /// The actions the service description lists. Throws when the renderer names none or it
    /// can't be read.
    package func actions() async throws(DescriptionProblem) -> Set<String> {
        guard let description = transport.description else {
            throw .unreadable("the renderer names no AVTransport description")
        }
        let bytes: [UInt8]
        do throws(LocalNetworkError) {
            bytes = try await LocalHTTPClient.get(description, timeoutSeconds: timeoutSeconds)
        } catch {
            throw .unreadable("its AVTransport description wasn't fetched: \(error)")
        }
        return try serviceActions(bytes)
    }
}

extension AVTransport {
    /// A `GetTransportInfo` reply's body, read as `AVTransportControl` reads it.
    package static func transportInfo(fromReply reply: [UInt8]) throws(DescriptionProblem)
        -> TransportInfo
    {
        try TransportInfo(transportInfo.response(reply))
    }

    /// A `GetPositionInfo` reply's body, read as `AVTransportControl` reads it.
    package static func positionInfo(fromReply reply: [UInt8]) throws(DescriptionProblem)
        -> PositionInfo
    {
        PositionInfo(try positionInfo.response(reply))
    }
}

/// What `GetTransportInfo` says.
package struct TransportInfo: Equatable, Sendable {
    package enum State: Equatable, Sendable {
        case playing, paused, stopped, transitioning, noMedia
        /// A state the spec doesn't name, kept for reports and cut short.
        case other(String)
    }

    package let state: State
    /// False when the renderer reports `ERROR_OCCURRED`.
    package let isOK: Bool

    init(_ reply: XMLTree) throws(DescriptionProblem) {
        guard let state = reply.value("CurrentTransportState") else {
            throw .unreadable("it has no CurrentTransportState")
        }
        switch state {
        case "PLAYING": self.state = .playing
        case "PAUSED_PLAYBACK": self.state = .paused
        case "STOPPED": self.state = .stopped
        case "TRANSITIONING": self.state = .transitioning
        case "NO_MEDIA_PRESENT": self.state = .noMedia
        default: self.state = .other(shown(state))
        }
        isOK = reply.value("CurrentTransportStatus") != "ERROR_OCCURRED"
    }
}

/// What `GetPositionInfo` says about the track the renderer has.
package struct PositionInfo: Equatable, Sendable {
    /// Empty when it has none.
    package let trackURI: String
    /// Nil when the renderer doesn't say, or says something that isn't a time.
    package let seconds: Double?
    package let durationSeconds: Double?

    init(_ reply: XMLTree) {
        trackURI = reply.value("TrackURI") ?? ""
        seconds = reply.value("RelTime").flatMap(upnpSeconds)
        durationSeconds = reply.value("TrackDuration").flatMap(upnpSeconds)
    }
}

/// Longest time a renderer's reply may give, a little over 11 days; anything longer is a lie.
let upnpTimeCapSeconds = 999_999.0

/// `H+:MM:SS` with an optional fraction, as AVTransport writes times. Nil for anything else,
/// such as `NOT_IMPLEMENTED`, minutes or seconds of 60 or more, or a time past the cap.
func upnpSeconds(_ text: String) -> Double? {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, (1...6).contains(parts[0].count), parts[1].count == 2,
        parts[0].allSatisfy(\.isASCIIDigit), parts[1].allSatisfy(\.isASCIIDigit),
        let hours = Int(parts[0]), let minutes = Int(parts[1]), minutes < 60
    else { return nil }
    let secondParts = parts[2].split(separator: ".", omittingEmptySubsequences: false)
    guard (1...2).contains(secondParts.count), secondParts[0].count == 2,
        secondParts[0].allSatisfy(\.isASCIIDigit), let seconds = Int(secondParts[0]), seconds < 60
    else { return nil }
    var fraction = 0.0
    if secondParts.count == 2 {
        let digits = secondParts[1]
        guard (1...9).contains(digits.count), digits.allSatisfy(\.isASCIIDigit),
            let value = Int(digits)
        else { return nil }
        fraction = Double(value) / pow10(digits.count)
    }
    let total = Double(hours * 3600 + minutes * 60 + seconds) + fraction
    return total <= upnpTimeCapSeconds ? total : nil
}

/// `seconds` as `H:MM:SS`, whole seconds, which every renderer takes as a seek target.
func upnpTime(_ seconds: Double) -> String {
    let whole = Int(min(max(seconds, 0), upnpTimeCapSeconds))
    let minutes = (whole / 60) % 60
    let secs = whole % 60
    return "\(whole / 3600):\(minutes < 10 ? "0" : "")\(minutes):\(secs < 10 ? "0" : "")\(secs)"
}

private func pow10(_ exponent: Int) -> Double {
    (0..<exponent).reduce(1.0) { value, _ in value * 10 }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}

/// The action names a service description lists, such as AVTransport's, which say whether the
/// renderer has `SetNextAVTransportURI`. Names past `actionCap` are left out.
package func serviceActions(_ bytes: [UInt8]) throws(DescriptionProblem) -> Set<String> {
    let scpd: XMLTree
    do throws(XMLProblem) {
        scpd = try XMLTree.parse(bytes)
    } catch {
        throw .unreadable("\(error)")
    }
    guard scpd.name == "scpd", let list = scpd.child("actionList") else {
        throw .unreadable("it isn't a service description with an action list")
    }
    return Set(
        list.children.filter { $0.name == "action" }.prefix(serviceActionCap).compactMap {
            $0.value("name")
        })
}

/// Most actions a service description keeps; the captured AVTransports list under 70.
let serviceActionCap = 256
