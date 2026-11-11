import Foundation
import Testing

@testable import Settings

/// Every way `value` can be printed: interpolation, both descriptions, `dump` and its mirror.
private func printings(_ value: Any) -> [String] {
    var dumped = ""
    dump(value, to: &dumped)
    let mirror = Mirror(reflecting: value)
    return [
        String(describing: value), String(reflecting: value), "\(value)", dumped,
        mirror.children.map { "\($0.label ?? "") \($0.value)" }.joined(),
    ]
}

@Test func bothTokensPrintRedactedEveryWay() {
    let text = "fakeSECRETfor7tests0nly"
    for (value, redacted) in [
        (DiscogsToken(text) as Any, "<Discogs token>"), (ServiceToken(text), "<service token>"),
    ] {
        for printed in printings(value) {
            #expect(!printed.contains(text), "\(printed)")
        }
        #expect(String(describing: value) == redacted)
        #expect(String(reflecting: value) == redacted)
        #expect(Mirror(reflecting: value).children.isEmpty)
    }
}

@Test func bothTokensAreStoredAsABareString() throws {
    let text = "fakeSECRETfor7tests0nly"
    let json = Data(#""\#(text)""#.utf8)
    #expect(try JSONEncoder().encode(DiscogsToken(text)) == json)
    #expect(try JSONEncoder().encode(ServiceToken(text)) == json)
    #expect(try JSONDecoder().decode(DiscogsToken.self, from: json).secret == text)
    #expect(try JSONDecoder().decode(ServiceToken.self, from: json).secret == text)
}
