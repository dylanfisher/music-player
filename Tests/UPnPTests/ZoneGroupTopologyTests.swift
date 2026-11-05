import Testing

@testable import UPnP

/// A `GetZoneGroupState` reply holding `state` escaped, as Sonos sends it.
private func reply(_ state: String) -> [UInt8] {
    let escaped = state.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
    return Array(
        ("<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">"
            + "<s:Body><u:GetZoneGroupStateResponse xmlns:u=\"\(ZoneGroupTopology.serviceType)\">"
            + "<ZoneGroupState>\(escaped)</ZoneGroupState></u:GetZoneGroupStateResponse>"
            + "</s:Body></s:Envelope>").utf8)
}

/// Three groups as Sonos's documented state lists them: a stereo pair, two rooms played
/// together, and a home theater speaker whose sub and surrounds are satellites.
private let household = """
    <ZoneGroups>
    <ZoneGroup Coordinator="RINCON_A" ID="RINCON_A:1">
    <ZoneGroupMember UUID="RINCON_A" ZoneName="Top Floor" ChannelMapSet="RINCON_A:LF,LF;RINCON_B:RF,RF"/>
    <ZoneGroupMember UUID="RINCON_B" ZoneName="Top Floor" Invisible="1"/>
    </ZoneGroup>
    <ZoneGroup Coordinator="RINCON_D" ID="RINCON_D:7">
    <ZoneGroupMember UUID="RINCON_C" ZoneName="Living Room"/>
    <ZoneGroupMember UUID="RINCON_D" ZoneName="Kitchen &amp; Dining"/>
    </ZoneGroup>
    <ZoneGroup Coordinator="RINCON_E" ID="RINCON_E:3">
    <ZoneGroupMember UUID="RINCON_E" ZoneName="Den">
    <Satellite UUID="RINCON_F" ZoneName="Den" Invisible="1"/>
    </ZoneGroupMember>
    </ZoneGroup>
    </ZoneGroups>
    """

@Test func eachGroupIsNamedAsTheSonosAppNamesIt() throws {
    let groups = try ZoneGroupTopology.groups(
        reply("<ZoneGroupState>\(household)<VanishedDevices/></ZoneGroupState>"))
    #expect(groups.map(\.coordinator) == ["RINCON_A", "RINCON_D", "RINCON_E"])
    #expect(groups.map(\.name) == ["Top Floor", "Kitchen & Dining + 1", "Den"])
    #expect(groups[0].members.map(\.isVisible) == [true, false])
    // A satellite isn't a member of its own.
    #expect(groups[2].members.map(\.id) == ["RINCON_E"])
}

@Test func anOlderPlayersStateWithoutItsWrapperReadsTheSame() throws {
    let groups = try ZoneGroupTopology.groups(reply(household))
    #expect(groups.map(\.name) == ["Top Floor", "Kitchen & Dining + 1", "Den"])
}

@Test func aStateThatIsntOneIsRefused() {
    #expect(throws: DescriptionProblem.self) { try ZoneGroupTopology.groups(reply("plain")) }
    #expect(throws: DescriptionProblem.self) {
        try ZoneGroupTopology.groups(reply("<!DOCTYPE x><ZoneGroups/>"))
    }
    #expect(throws: DescriptionProblem.self) { try ZoneGroupTopology.groups(reply("<Other/>")) }
}
