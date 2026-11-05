/// Sonos's ZoneGroupTopology service: which players play together, and the room each is in
/// (ADR 0093). Every player answers for the whole household, so one reply names every group.
enum ZoneGroupTopology {
    static let serviceType = "urn:schemas-upnp-org:service:ZoneGroupTopology:1"

    static var request: SOAPAction { SOAPAction(serviceType, "GetZoneGroupState") }

    /// Players that play together. The coordinator plays for all of them, so it's the one a
    /// track is sent to.
    struct Group: Equatable, Sendable {
        /// The coordinator's player ID, `RINCON_…`.
        var coordinator: String
        var members: [Member]

        /// What the Sonos app calls the group: its room's name when every player in it is in one
        /// room, as a stereo pair or a speaker with a sub is, or else the coordinator's room
        /// and "+ 1" or more for the other rooms.
        var name: String {
            var rooms: [String] = []
            let leading = members.first { $0.id == coordinator }
            for member in [leading].compactMap({ $0 }) + members
            where member.isVisible && !rooms.contains(member.room) {
                rooms.append(member.room)
            }
            guard let first = rooms.first else { return leading?.room ?? "" }
            return rooms.count == 1 ? first : "\(first) + \(rooms.count - 1)"
        }
    }

    struct Member: Equatable, Sendable {
        /// `RINCON_…`, the player's root device's UDN without `uuid:`.
        var id: String
        var room: String
        /// False for the second speaker of a pair, a sub or a surround, which the Sonos app
        /// doesn't show as a room of its own.
        var isVisible: Bool
    }

    /// The groups in a `GetZoneGroupState` reply. The state is an XML document escaped inside
    /// the reply's `ZoneGroupState`, under a `ZoneGroupState` element or, from older players,
    /// at its root as `ZoneGroups`; it's read with the same caps as any document.
    static func groups(_ reply: [UInt8]) throws(DescriptionProblem) -> [Group] {
        guard let state = try request.response(reply).child("ZoneGroupState") else {
            throw .unreadable("its reply has no ZoneGroupState")
        }
        let root: XMLTree
        do throws(XMLProblem) {
            root = try XMLTree.parse(Array(state.text.utf8))
        } catch {
            throw .unreadable("its ZoneGroupState can't be read: \(error)")
        }
        guard let groups = root.name == "ZoneGroups" ? root : root.child("ZoneGroups") else {
            throw .unreadable("its ZoneGroupState has no ZoneGroups")
        }
        return groups.children.filter { $0.name == "ZoneGroup" }.compactMap { group in
            guard let coordinator = group.attributes["Coordinator"] else { return nil }
            let members = group.children.filter { $0.name == "ZoneGroupMember" }.compactMap {
                member -> Member? in
                guard let id = member.attributes["UUID"] else { return nil }
                return Member(
                    id: id, room: shown(member.attributes["ZoneName"]),
                    isVisible: member.attributes["Invisible"] != "1")
            }
            return members.isEmpty ? nil : Group(coordinator: coordinator, members: members)
        }
    }

    /// `renderers` with each Sonos player in `groups` named as its group and pointed at its
    /// coordinator.
    static func apply(_ groups: [Group], to renderers: [Renderer]) -> [Renderer] {
        renderers.map { renderer in
            guard let id = renderer.sonos?.playerID,
                let group = groups.first(where: { $0.members.contains { $0.id == id } })
            else { return renderer }
            var grouped = renderer
            grouped.sonos?.coordinator = group.coordinator
            grouped.name = group.name
            return grouped
        }
    }
}
