extension CatalogRelease {
    /// Whether `other` is this release in every tag the matcher compares, as YATE writes them
    /// (ADR 0128): the tracklist as files hold it, the first label's catalog number, the first
    /// barcode, the release date, `MEDIA` and the country. The
    /// owner decided on 2026-11-07 that the tuning counts such a twin as the release itself
    /// (ADR 0131).
    public func isTwin(of other: CatalogRelease) -> Bool {
        twinKey == other.twinKey
    }

    private var twinKey: [[String]] {
        [
            ReleaseTracklist.flattenings(tracks)[0].map { CatalogKey.fold($0.title, title: true) },
            [labels.first?.catalogNumber.flatMap(CatalogKey.catalogNumber) ?? ""],
            [barcodes.first.map(CatalogKey.barcode) ?? ""],
            [released ?? "", country ?? ""],
            formats.map(mediaText),
        ]
    }
}
