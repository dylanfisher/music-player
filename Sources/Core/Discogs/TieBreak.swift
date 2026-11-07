import Foundation
import Library

/// The owner's order for releases that fit an album's tracklist equally (decided 2026-11-07):
/// one whose barcode or catalog number the album's tags carry, then one on a digital or CD
/// format rather than vinyl or another, then its master's main release. A number spelled as
/// the tags spell it comes before one that only folds the same, then a release whose format the
/// tags' `MEDIA` spells, then one dated as the tags' `DATE` (ADR 0131). Each step keeps the scores that pass it, when any do; more than one left is
/// still a tie.
func tieBreak(
    _ scores: [ReleaseScore], releases: [Int: CatalogRelease], album: DiscogsAlbum
) -> [ReleaseScore] {
    let barcode = album.barcode.map(CatalogKey.barcode).flatMap { $0.isEmpty ? nil : $0 }
    let number = album.catalogNumber.flatMap(CatalogKey.catalogNumber)
    let spelled = [album.barcode, album.catalogNumber].compactMap {
        $0?.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    let steps: [(CatalogRelease, ReleaseScore) -> Bool] = [
        { release, _ in
            release.barcodes.contains { spelled.contains($0) }
                || release.labels.contains { $0.catalogNumber.map(spelled.contains) ?? false }
        },
        { release, _ in
            if let barcode, release.barcodes.map(CatalogKey.barcode).contains(barcode) {
                return true
            }
            guard let number else { return false }
            return release.labels.contains {
                $0.catalogNumber.flatMap(CatalogKey.catalogNumber) == number
            }
        },
        { release, _ in album.media.map { release.formats.map(mediaText).contains($0) } ?? false },
        { release, _ in album.date != nil && release.released == album.date },
        { release, _ in release.formats.contains { preferredFormats.contains($0.name) } },
        { release, _ in release.isMainRelease },
    ]
    var left = scores
    for step in steps where left.count > 1 {
        let passing = left.filter { score in
            releases[score.releaseID].map { step($0, score) } ?? false
        }
        if !passing.isEmpty { left = passing }
    }
    return left
}

/// The formats the tie-break prefers: a download, or a CD of any kind.
let preferredFormats: Set<String> = ["File", "CD", "CDr", "SACD"]

/// A format as YATE writes it to `MEDIA`: its name, and its descriptions in brackets joined
/// with "," when it has any (ADR 0128).
func mediaText(_ format: CatalogRelease.Format) -> String {
    format.descriptions.isEmpty
        ? format.name : "\(format.name) (\(format.descriptions.joined(separator: ",")))"
}
