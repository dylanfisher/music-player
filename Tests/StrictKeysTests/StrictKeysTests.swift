import Foundation
import StrictKeys
import Testing

private struct Pair: Decodable, Equatable {
    var left: Int
    var right: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case left, right
    }

    init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        left = try container.decode(Int.self, forKey: .left)
        right = try container.decode(Int.self, forKey: .right)
    }
}

private func decoded(_ text: String) throws -> Pair {
    try JSONDecoder().decode(Pair.self, from: Data(text.utf8))
}

@Test func aStrictContainerReadsAnObjectWithOnlyItsKeys() throws {
    #expect(try decoded(#"{"left": 1, "right": 2}"#).right == 2)
}

@Test func aStrictContainerRefusesAMisspelledKey() {
    do {
        _ = try decoded(#"{"left": 1, "right": 2, "rihgt": 3}"#)
        Issue.record("accepted a misspelled key")
    } catch DecodingError.dataCorrupted(let context) {
        #expect(context.debugDescription == "unknown key")
        #expect(context.codingPath.map(\.stringValue) == ["rihgt"])
    } catch {
        Issue.record("\(error)")
    }
}
