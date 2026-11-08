import Foundation
import Settings

/// Which field a Discogs credit's role goes to (ADR 0132): the roles YATE gives a field of
/// their own, and the involved people for the rest.
enum CreditRole {
    static let composer: Set<String> = ["Composed By", "Written-By", "Music By", "Songwriter"]
    static let lyricist: Set<String> = ["Lyrics By", "Words By"]
    static let conductor: Set<String> = ["Conductor"]
    static let remixer: Set<String> = ["Remix"]
    static let producer: Set<String> = ["Producer"]

    /// The roles `field` takes; nil for the involved people, who take every other role, and
    /// for a field that isn't a credit.
    static func roles(_ field: DiscogsField) -> Set<String>? {
        switch field {
        case .composer: composer
        case .lyricist: lyricist
        case .conductor: conductor
        case .remixer: remixer
        case .producer: producer
        default: nil
        }
    }

    static let ownFields: Set<String> = composer.union(lyricist).union(conductor).union(remixer)
        .union(producer)

    /// The roles a credit's text names, without the notes in brackets: "Producer, Recorded By
    /// [Live]" is "Producer" and "Recorded By".
    static func split(_ role: String) -> [String] {
        var roles: [String] = []
        var current = ""
        var depth = 0
        for character in role {
            switch character {
            case "[": depth += 1
            case "]": depth = max(0, depth - 1)
            case "," where depth == 0:
                roles.append(current)
                current = ""
            default: if depth == 0 { current.append(character) }
            }
        }
        roles.append(current)
        return roles.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
