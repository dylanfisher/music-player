import Testing

@testable import LocalNetwork

/// A made-up interface, as the tests' interface lists hold.
func interface(_ name: String, _ index: UInt32, _ address: String, _ prefix: Int)
    -> NetworkInterface
{
    NetworkInterface(name: name, index: index, address: IPAddress(address)!, prefixLength: prefix)
}

/// Loopback, standing in for a LAN interface, so tests' devices can live on it.
let loopback = interface("lo0", 1, "127.0.0.1", 8)

@Test func literalsParseAndNamesDont() {
    #expect(IPAddress("192.168.1.20") == .v4([192, 168, 1, 20]))
    #expect(IPAddress("::ffff:10.0.0.1") == .v4([10, 0, 0, 1]))
    #expect(IPAddress("fe80::1%4")?.description == "fe80::1%4")
    #expect(IPAddress("fe80::1%4")?.urlHost == "[fe80::1%254]")
    #expect(IPAddress("receiver.local") == nil)
    #expect(IPAddress("192.168.1.20%4") == nil)
    #expect(IPAddress("fe80::1%") == nil)
    #expect(IPAddress("") == nil)
}

@Test func anAddressIsLocalToTheInterfaceWhoseSubnetHoldsIt() {
    let wifi = interface("en0", 4, "192.168.1.10", 24)
    let wired = interface("en1", 5, "192.168.1.11", 24)
    let lab = interface("en2", 6, "10.1.0.5", 16)
    let narrow = interface("en3", 7, "10.1.2.5", 24)
    let subnets = LocalSubnets([wifi, wired, lab, narrow])
    // On one LAN by two interfaces, the first listed answers.
    #expect(subnets.interface(holding: IPAddress("192.168.1.200")!) == wifi)
    // The longest prefix wins over an earlier, wider one.
    #expect(subnets.interface(holding: IPAddress("10.1.2.9")!) == narrow)
    #expect(subnets.interface(holding: IPAddress("10.1.3.9")!) == lab)
    #expect(subnets.interface(holding: IPAddress("192.168.2.1")!) == nil)
    #expect(subnets.interface(holding: IPAddress("8.8.8.8")!) == nil)
}

@Test func aLinkLocalAddressCountsOnlyWithTheZoneItArrivedOn() {
    let wifi = interface("en0", 4, "fe80::aa%4", 64)
    let wired = interface("en1", 5, "fe80::bb%5", 64)
    let global = interface("en0", 4, "2001:db8:1::10", 64)
    let subnets = LocalSubnets([wifi, wired, global])
    #expect(subnets.interface(holding: IPAddress("fe80::1234%5")!) == wired)
    #expect(subnets.interface(holding: IPAddress("fe80::1234%4")!) == wifi)
    #expect(subnets.interface(holding: IPAddress("fe80::1234")!) == nil)
    #expect(subnets.interface(holding: IPAddress("fe80::1234%9")!) == nil)
    #expect(subnets.interface(holding: IPAddress("2001:db8:1::99")!) == global)
    #expect(subnets.interface(holding: IPAddress("2001:db8:2::99")!) == nil)
    // A family never matches the other.
    #expect(LocalSubnets([loopback]).interface(holding: IPAddress("::1")!) == nil)
}

@Test func theLiveListHasNoLoopback() throws {
    for found in try currentInterfaces() {
        #expect(found.address != IPAddress("127.0.0.1"))
        #expect(found.address != IPAddress("::1"))
    }
}

@Test func onlyPlainHTTPToAnAddressOnTheSubnetIsFollowed() throws {
    let lan = interface("en0", 4, "192.168.1.10", 24)
    let url = try LocalURL("http://192.168.1.20:60006/upnp/desc.xml?x=1", on: lan)
    #expect(url.host == IPAddress("192.168.1.20"))
    #expect(url.port == 60006)
    #expect(url.target == "/upnp/desc.xml?x=1")
    #expect(try LocalURL("http://192.168.1.20", on: lan).description == "http://192.168.1.20:80/")
    let refused = [
        "https://192.168.1.20/desc.xml", "ftp://192.168.1.20/", "http://denon.local/desc.xml",
        "http://user:pw@192.168.1.20/", "http://192.168.2.20/desc.xml", "http://8.8.8.8/",
        "http://192.168.1.20/a#b", "file:///etc/passwd", "//192.168.1.20/", "",
        "http://192.168.1.20:0/", "http://[fe80::1]/",
        "http://192.168.1.20/" + String(repeating: "a", count: 3000),
    ]
    for text in refused {
        #expect(throws: LocalURL.Refusal.self, "\(text)") { try LocalURL(text, on: lan) }
    }
    // A description's own URLs stay on its host and port.
    #expect(
        try url.resolving("/ctl/ConnectionManager").description
            == "http://192.168.1.20:60006/ctl/ConnectionManager")
    #expect(try url.resolving("ctl").description == "http://192.168.1.20:60006/upnp/ctl")
    #expect(throws: LocalURL.Refusal.otherHost("http://192.168.1.21:60006/ctl")) {
        try url.resolving("http://192.168.1.21:60006/ctl")
    }
    #expect(throws: LocalURL.Refusal.self) { try url.resolving("http://192.168.1.20:80/ctl") }
}

@Test func aLinkLocalHostTakesTheInterfaceItCameOn() throws {
    let lan = interface("en0", 4, "fe80::aa%4", 64)
    let url = try LocalURL("http://[fe80::1]:8080/d.xml", on: lan)
    #expect(url.host == IPAddress("fe80::1%4"))
    #expect(url.description == "http://[fe80::1%254]:8080/d.xml")
}

@Test func headsParseStrictly() {
    let reply = Array("HTTP/1.1 200 OK\r\nLocation: http://a/\r\nST: x\r\n\r\nbody".utf8)
    guard case .head(let head, let length) = HTTPHead.parse(reply[...], cap: 1024) else {
        Issue.record("not parsed")
        return
    }
    #expect(head.start == ["HTTP/1.1", "200", "OK"])
    #expect(head.value("LOCATION") == "http://a/")
    #expect(length == reply.count - 4)
    // A bare LF ends a line too.
    #expect(
        HTTPHead.parse(Array("GET / HTTP/1.1\nHost: a\n\n".utf8)[...], cap: 1024)
            != .incomplete)
    #expect(
        HTTPHead.parse(Array("GET / HTTP/1.1\r\nHost: a\r\n".utf8)[...], cap: 1024) == .incomplete)
    #expect(
        HTTPHead.parse(Array(repeating: UInt8(ascii: "a"), count: 50)[...], cap: 40) == .tooLarge)
    let bad = [
        "GET / HTTP/1.1\r\nHost: a\r\n folded\r\n\r\n", "GET /\r\n\r\n",
        "GET / HTTP/1.1\r\nHo st: a\r\n\r\n", "GET / HTTP/1.1\r\n: a\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: \u{1B}[2J\r\n\r\n", "\r\n\r\n",
    ]
    for text in bad {
        guard case .malformed = HTTPHead.parse(Array(text.utf8)[...], cap: 1024) else {
            Issue.record("\(text.debugDescription) wasn't refused")
            continue
        }
    }
    let many = "GET / HTTP/1.1\r\n" + String(repeating: "A: b\r\n", count: 101) + "\r\n"
    #expect(HTTPHead.parse(Array(many.utf8)[...], cap: 8192) == .malformed("over 100 fields"))
}
