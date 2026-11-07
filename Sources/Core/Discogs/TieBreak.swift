import Library

/// The owner's order for releases that fit an album equally (decided 2026-11-07): one whose
/// barcode or catalog number the album's tags carry, then one on a digital or CD format
/// rather than vinyl or another, then its master's main release. Each step keeps the releases
/// that pass it, when any do; more than one left is still a tie.
func tieBreak(_ releases: [CatalogRelease], album: DiscogsAlbum) -> [CatalogRelease] {
    let barcode = album.barcode.map(CatalogKey.barcode).flatMap { $0.isEmpty ? nil : $0 }
    let number = album.catalogNumber.flatMap(CatalogKey.catalogNumber)
    let steps: [(CatalogRelease) -> Bool] = [
        { release in
            if let barcode, release.barcodes.map(CatalogKey.barcode).contains(barcode) {
                return true
            }
            guard let number else { return false }
            return release.labels.contains {
                $0.catalogNumber.flatMap(CatalogKey.catalogNumber) == number
            }
        },
        { release in release.formats.contains { preferredFormats.contains($0.name) } },
        { release in release.isMainRelease },
    ]
    var left = releases
    for step in steps where left.count > 1 {
        let passing = left.filter(step)
        if !passing.isEmpty { left = passing }
    }
    return left
}

/// The formats the tie-break prefers: a download, or a CD of any kind.
let preferredFormats: Set<String> = ["File", "CD", "CDr", "SACD"]
