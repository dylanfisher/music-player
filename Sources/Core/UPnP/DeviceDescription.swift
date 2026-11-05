import DisplayText

/// What a UPnP device description says about the devices in it (ADR 0039). Every field is the
/// device's own text, so names are escaped before anything shows them.
public struct DeviceDescription: Equatable, Sendable {
    public struct Device: Equatable, Sendable {
        var deviceType: String
        /// Escaped as display text and cut to `nameCap` characters.
        public var name: String
        public var manufacturer: String
        public var model: String
        /// The room a Sonos player is in, which its root device names; nil for other devices.
        var room: String?
        var udn: String
        var services: [Service]
    }

    struct Service: Equatable, Sendable {
        var serviceType: String
        /// As the description gives it, often relative to the description's URL.
        var controlURL: String
        /// The service's own description, or nil when the device lists none.
        var scpdURL: String?
    }

    /// The root device first, then the devices nested in it, depth first.
    public var devices: [Device]

    /// Longest name, manufacturer or model kept.
    static let nameCap = 256
    /// Most devices and services kept.
    static let deviceCap = 16
    static let serviceCap = 32

    /// Reads a description; the caps on its size and shape are `XMLTree`'s.
    public init(_ bytes: [UInt8]) throws(DescriptionProblem) {
        let root: XMLTree
        do throws(XMLProblem) {
            root = try XMLTree.parse(bytes)
        } catch {
            throw .unreadable("\(error)")
        }
        guard root.name == "root", let device = root.child("device") else {
            throw .unreadable("it has no root device")
        }
        var found: [Device] = []
        func visit(_ element: XMLTree) {
            guard found.count < Self.deviceCap else { return }
            let services = (element.child("serviceList")?.children ?? [])
                .filter { $0.name == "service" }.prefix(Self.serviceCap)
                .compactMap { service -> Service? in
                    guard let type = service.value("serviceType"),
                        let control = service.value("controlURL")
                    else { return nil }
                    return Service(
                        serviceType: type, controlURL: control, scpdURL: service.value("SCPDURL"))
                }
            found.append(
                Device(
                    deviceType: element.value("deviceType") ?? "",
                    name: shown(element.value("friendlyName")),
                    manufacturer: shown(element.value("manufacturer")),
                    model: shown(element.value("modelName")),
                    room: element.value("roomName").map(shown), udn: shown(element.value("UDN")),
                    services: Array(services)))
            for child in element.child("deviceList")?.children ?? [] where child.name == "device" {
                visit(child)
            }
        }
        visit(device)
        devices = found
    }

    /// The first device of `type`.
    func device(ofType type: String) -> Device? {
        devices.first { $0.deviceType == type }
    }
}

extension DeviceDescription.Device {
    /// The first service of `type`.
    func service(ofType type: String) -> DeviceDescription.Service? {
        services.first { $0.serviceType == type }
    }
}

/// A device's text as the app shows it: one line, control characters escaped, cut short.
func shown(_ text: String?) -> String {
    terminalSafe(String((text ?? "").prefix(DeviceDescription.nameCap)))
}

/// Why a description or a SOAP reply wasn't taken.
public enum DescriptionProblem: Error, Equatable, CustomStringConvertible {
    case unreadable(String)

    public var description: String {
        switch self {
        case .unreadable(let why): why
        }
    }
}
