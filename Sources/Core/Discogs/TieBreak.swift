import Foundation
import Library

/// The order for releases that fit an album's tracklist equally, which the owner approved on
/// 2026-11-07 (ADR 0131): a barcode or catalog number spelled as the tags spell it, then one
/// that folds the same, then the format the tags' `MEDIA` names, then the tags' `DATE`, then
/// their country, then a digital or CD format rather than vinyl or another, then a standard
/// edition rather than a limited, special or promotional one of the same pressing, then the
/// master's main release. `MEDIA`, `DATE` and the country match as written first, then as Discogs has
/// since filled them in or changed them: more descriptions, a fuller date, a region that names
/// the country. A `DATE` of a year alone only fits, since a year tells no pressings apart. A number on the first label, which is the one YATE writes,
/// beats one on another, and a release with both the barcode and the number beats one with
/// either. Each step keeps the scores that pass it best, when any pass; more than one left
/// is still a tie.
///
/// The release chosen is the one the owner's preferences put first among those the steps
/// before the main release leave (ADR 0131, 2026-11-09): the country most of them share, then
/// a first pressing rather than a repress or reissue, then the main release, then a standard
/// edition. They only order the tie: the choice is untied only when the main release alone
/// leaves the same one release.
func tieBreak(
    _ scores: [ReleaseScore], releases: [Int: CatalogRelease], album: DiscogsAlbum
) -> (ReleaseScore, tied: Bool) {
    let barcode = album.barcode.map(CatalogKey.barcode).flatMap { $0.isEmpty ? nil : $0 }
    let number = album.catalogNumber.flatMap(CatalogKey.catalogNumber)
    let spelledBarcode = barcode == nil ? nil : album.barcode?.trimmingCharacters(in: .whitespaces)
    let spelledNumber = album.catalogNumber?.trimmingCharacters(in: .whitespaces)
    // Each step gives a release a weight; the releases of the highest weight above 0 stay.
    // A catalog number counts double on the first label, which `CATALOGNUMBER` is (ADR 0128).
    func numberWeight(_ release: CatalogRelease, _ same: (String) -> Bool) -> Int {
        release.labels.enumerated().compactMap { index, label in
            label.catalogNumber.map { same($0) ? (index == 0 ? 2 : 1) : 0 }
        }.max() ?? 0
    }
    var left = scores
    // The releases still tied, which the edition step compares each release with.
    func tied() -> [CatalogRelease] { left.compactMap { releases[$0.releaseID] } }
    let steps: [(CatalogRelease) -> Int] = [
        { release in
            (spelledBarcode.map { release.barcodes.contains($0) ? 1 : 0 } ?? 0)
                + (spelledNumber.map { number in numberWeight(release) { $0 == number } } ?? 0)
        },
        { release in
            (barcode.map { release.barcodes.map(CatalogKey.barcode).contains($0) ? 1 : 0 } ?? 0)
                + (number.map { number in
                    numberWeight(release) { CatalogKey.catalogNumber($0) == number }
                } ?? 0)
        },
        { release in
            album.media.map { release.formats.map(mediaText).contains($0) ? 1 : 0 } ?? 0
        },
        { release in
            album.media.map { media in release.formats.contains { fits(media, $0) } ? 1 : 0 }
                ?? 0
        },
        { release in
            guard let date = album.date, date.count > 4 else { return 0 }
            return release.released == date ? 1 : 0
        },
        { release in
            guard let date = album.date, let released = release.released else { return 0 }
            return datesFit(date, released) ? 1 : 0
        },
        { release in album.country != nil && release.country == album.country ? 1 : 0 },
        { release in
            guard let country = album.country, let released = release.country else { return 0 }
            return countriesFit(country, released) ? 1 : 0
        },
        { release in release.formats.contains { preferredFormats.contains($0.name) } ? 1 : 0 },
        { release in
            !isEdition(release)
                || !tied().contains { !isEdition($0) && samePressing(release, $0) } ? 1 : 0
        },
    ]
    let main: (CatalogRelease) -> Int = { release in release.isMainRelease ? 1 : 0 }
    let preferences: [(CatalogRelease) -> Int] = [
        { release in
            guard let country = release.country else { return 0 }
            return tied().filter { other in
                other.id != release.id && other.country.map { countriesFit(country, $0) } ?? false
            }.count
        },
        { release in
            release.formats.contains { !laterPressings.isDisjoint(with: $0.descriptions) } ? 0 : 1
        },
        main,
        { release in isEdition(release) ? 0 : 1 },
    ]
    func run(_ steps: [(CatalogRelease) -> Int]) {
        for step in steps where left.count > 1 {
            let weights = left.map { score in releases[score.releaseID].map(step) ?? 0 }
            guard let top = weights.max(), top > 0 else { continue }
            left = zip(left, weights).filter { $0.1 == top }.map(\.0)
        }
    }
    run(steps)
    let tie = left
    run([main])
    let decided = left
    left = tie
    run(preferences)
    let untied = decided.count == 1 && left.count == 1 && decided[0].releaseID == left[0].releaseID
    return (left[0], !untied)
}

/// The formats the tie-break prefers: a download, or a CD of any kind.
let preferredFormats: Set<String> = ["File", "CD", "CDr", "SACD"]

/// The format descriptions Discogs gives an edition other than the standard one, which the
/// tie-break passes over when a standard release of the same pressing fits as well.
let editionDescriptions: Set<String> = [
    "Limited Edition", "Numbered", "Special Edition", "Deluxe Edition", "Club Edition", "Promo",
    "Test Pressing", "White Label", "Unofficial Release",
]

/// The format descriptions Discogs gives a pressing after the first, which the tie-break puts
/// after a first pressing among releases still tied.
let laterPressings: Set<String> = ["Repress", "Reissue", "Remastered"]

/// Whether a format of the release names it a limited, special or promotional edition.
func isEdition(_ release: CatalogRelease) -> Bool {
    release.formats.contains { !editionDescriptions.isDisjoint(with: $0.descriptions) }
}

/// Whether two releases are one pressing in two editions: the first label's catalog number
/// the same once folded, or the same release date to the month at least. A limited original
/// and a later download of it differ in both, so the main release still decides between them.
func samePressing(_ a: CatalogRelease, _ b: CatalogRelease) -> Bool {
    guard a.formats.first?.name == b.formats.first?.name else { return false }
    let numbers = [a, b].map { $0.labels.first?.catalogNumber.flatMap(CatalogKey.catalogNumber) }
    if let number = numbers[0], number == numbers[1] { return true }
    guard let first = a.released, let second = b.released else { return false }
    let months = [first, second].map { $0.prefix(7) }
    return months.allSatisfy { $0.count == 7 && !$0.hasSuffix("-00") } && datesFit(first, second)
}

/// A format as YATE writes it to `MEDIA`: its name, and its descriptions in brackets joined
/// with "," when it has any (ADR 0128).
func mediaText(_ format: CatalogRelease.Format) -> String {
    format.descriptions.isEmpty
        ? format.name : "\(format.name) (\(format.descriptions.joined(separator: ",")))"
}

/// Whether the first format a `MEDIA` tag names is `format`, with its descriptions among the
/// format's: "Vinyl (LP)" fits a release Discogs now lists as "Vinyl (LP,Stereo)".
func fits(_ media: String, _ format: CatalogRelease.Format) -> Bool {
    let first = media.components(separatedBy: "), ")[0]
    guard let open = first.range(of: " (") else { return first == format.name }
    guard first[..<open.lowerBound] == format.name else { return false }
    let descriptions = first[open.upperBound...].trimmingCharacters(in: ["(", ")"])
        .components(separatedBy: ",")
    return Set(descriptions).isSubset(of: format.descriptions)
}

/// Whether two dates as Discogs writes them ("1965", "1965-01-00", "1965-01-15") are the same
/// day as far as both say.
func datesFit(_ a: String, _ b: String) -> Bool {
    func known(_ date: String) -> String {
        var date = date
        while date.hasSuffix("-00") { date.removeLast(3) }
        return date
    }
    let (a, b) = (known(a), known(b))
    return a.count >= 4 && b.count >= 4 && (a.hasPrefix(b) || b.hasPrefix(a))
}

/// Whether two countries as Discogs writes them name one place: the same once folded, or one
/// a part of the other's " & " list ("UK" and "UK & Europe").
func countriesFit(_ a: String, _ b: String) -> Bool {
    func parts(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: " & ").map { CatalogKey.fold($0) }.filter { !$0.isEmpty })
    }
    let (a, b) = (parts(a), parts(b))
    return !a.isEmpty && !b.isEmpty && (a.isSubset(of: b) || b.isSubset(of: a))
}
