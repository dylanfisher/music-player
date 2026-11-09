import Foundation
import Metadata
import Settings

/// A Discogs field's value before a rule's format makes it text (ADR 0132).
enum MappedValue: Equatable {
    case text(String)
    case list([String])
    /// Labels' names, which can carry Discogs's "(2)" as artists' do, and repeat where a label
    /// has several catalog numbers.
    case names([String])
    /// Names with Discogs's join words between them.
    case artists([CatalogArtistCredit])
    /// Credited people; the role is nil where only the names are written.
    case people([Person])

    struct Person: Equatable {
        var name: String
        var nameVariation: String?
        var role: String?
    }

    /// The values a numbered target writes one to a key, in `format`.
    func values(_ format: DiscogsFieldFormat, tagFormat: TagFormat) -> [String] {
        switch self {
        case .text(let text): [text]
        case .list(let values): values
        case .names(let names):
            names.map { name($0, nil, format) }.filter(
                format.repeats == .keep ? { _ in true } : once())
        case .artists(let artists):
            artists.map { name($0.name, $0.nameVariation, format) }
        case .people(let people):
            entries(people, format, style: format.creditStyle(in: tagFormat))
        }
    }

    /// The value as one text, its values joined by `format.join`, or for artists without one
    /// by Discogs's join words: "Alice Coltrane Featuring Pharoah Sanders", "Benedek , Tom
    /// Noble", as YATE writes them (ADR 0128).
    func text(_ format: DiscogsFieldFormat, tagFormat: TagFormat) -> String? {
        if case .artists(let artists) = self, format.join == nil {
            guard !artists.isEmpty else { return nil }
            var text = ""
            for (index, artist) in artists.enumerated() {
                text += name(artist.name, artist.nameVariation, format)
                if index < artists.count - 1 {
                    let join = artist.join?.trimmingCharacters(in: .whitespaces) ?? ""
                    text += " \(join.isEmpty ? "," : join) "
                }
            }
            return text
        }
        let values = values(format, tagFormat: tagFormat)
        return values.isEmpty ? nil : values.joined(separator: format.join ?? "")
    }
}

/// A filter that keeps each value the first time it sees it.
private func once() -> (String) -> Bool {
    var seen = Set<String>()
    return { seen.insert($0).inserted }
}

/// An artist's name as `format` writes it: the canonical one or the release's variation, and
/// with or without Discogs's "(2)".
func name(_ canonical: String, _ variation: String?, _ format: DiscogsFieldFormat) -> String {
    let name = format.names == .variation ? (variation ?? canonical) : canonical
    return format.suffixes == .drop ? CatalogKey.withoutNumberSuffix(name) : name
}

/// The people as `style` writes each: "Name (Role)" for each, or each role once with its
/// names, "Role;;;Name,Name", as YATE writes MP4's and ID3's credits. Names only where a
/// person has no role, each once.
private func entries(
    _ people: [MappedValue.Person], _ format: DiscogsFieldFormat,
    style: DiscogsFieldFormat.CreditStyle
) -> [String] {
    var seen = Set<String>()
    func once(_ text: String) -> Bool { seen.insert(text).inserted }
    if people.allSatisfy({ $0.role == nil }) {
        return people.map { name($0.name, $0.nameVariation, format) }.filter(once)
    }
    switch style {
    case .nameRole:
        return people.map { person in
            "\(name(person.name, person.nameVariation, format)) (\(person.role ?? ""))"
        }.filter(once)
    case .roleNames:
        var roles: [String] = []
        var names: [String: [String]] = [:]
        for person in people {
            let role = person.role ?? ""
            if names[role] == nil { roles.append(role) }
            let written = name(person.name, person.nameVariation, format)
            if names[role]?.contains(written) != true { names[role, default: []].append(written) }
        }
        return roles.map { role in
            role + DiscogsKey.valueSeparator + names[role]!.joined(separator: ",")
        }
    }
}
