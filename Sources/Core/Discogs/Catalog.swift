import Foundation
import SQLite

/// The catalog an import built, opened read-only (ADR 0130). Belongs to one thread or actor,
/// as its connection does.
public final class Catalog {
    /// A master, or a release with no master, that an album's artist and title fold to.
    enum TitleMatch: Equatable, Sendable {
        case master(Int)
        case release(Int)
    }

    /// The date of the dump the catalog was built from.
    let dumpDate: String

    private let database: Database
    private let decoder = JSONDecoder()

    /// Opens the catalog at `url`. Throws `CatalogError.missing` when there's none, and
    /// `.builtByAnotherVersion` when its tables aren't the ones this build writes.
    public init(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CatalogError.missing(url.path)
        }
        database = try Database(readOnlyAt: url)
        let identity = try database.prepare("SELECT dump_date, schema FROM catalog").map { row in
            (date: try row.text(0), schema: try row.text(1))
        }
        guard identity.count == 1, identity[0].schema == CatalogSchema.identity else {
            throw CatalogError.builtByAnotherVersion(url.path)
        }
        dumpDate = identity[0].date
    }

    public func release(id: Int) throws -> CatalogRelease? {
        try database.prepare(
            """
            SELECT master_id, is_main_release, title, country, released, lists
            FROM releases WHERE id = ?
            """
        ).map(id) { row in
            let lists = try decoder.decode(
                CatalogRelease.Lists.self, from: Data(try row.text(5).utf8))
            return CatalogRelease(
                id: id, masterID: row.optionalInt(0), isMainRelease: try row.int(1) == 1,
                title: try row.text(2), artists: lists.artists, labels: lists.labels,
                formats: lists.formats, country: row.optionalText(3),
                released: row.optionalText(4), genres: lists.genres, styles: lists.styles,
                barcodes: lists.barcodes, credits: lists.credits, tracks: lists.tracks)
        }.first
    }

    func master(id: Int) throws -> CatalogMaster? {
        try database.prepare(
            "SELECT main_release_id, title, year, lists FROM masters WHERE id = ?"
        ).map(id) { row in
            let lists = try decoder.decode(
                CatalogMaster.Lists.self, from: Data(try row.text(3).utf8))
            return CatalogMaster(
                id: id, mainReleaseID: row.optionalInt(0), title: try row.text(1),
                year: row.optionalInt(2), artists: lists.artists, genres: lists.genres,
                styles: lists.styles)
        }.first
    }

    func artist(id: Int) throws -> CatalogArtist? {
        try database.prepare("SELECT name, name_variations FROM artists WHERE id = ?").map(id) {
            row in
            CatalogArtist(
                id: id, name: try row.text(0),
                nameVariations: try decoder.decode([String].self, from: Data(try row.text(1).utf8)))
        }.first
    }

    func label(id: Int) throws -> CatalogLabel? {
        try database.prepare("SELECT name FROM labels WHERE id = ?").map(id) { row in
            CatalogLabel(id: id, name: try row.text(0))
        }.first
    }

    /// The releases of the master `id`, in id order.
    func releaseIDs(master id: Int) throws -> [Int] {
        try database.prepare("SELECT id FROM releases WHERE master_id = ? ORDER BY id").map(id) {
            try $0.int(0)
        }
    }

    /// The releases with `barcode`, however it's spaced or punctuated, in id order.
    func releaseIDs(barcode: String) throws -> [Int] {
        let key = CatalogKey.barcode(barcode)
        guard !key.isEmpty else { return [] }
        return try database.prepare(
            "SELECT release_id FROM barcode_keys WHERE barcode_key = ? ORDER BY release_id"
        ).map(key) { try $0.int(0) }
    }

    /// The releases with `catalogNumber` on a label whose name folds as `label`'s does.
    func releaseIDs(label: String, catalogNumber: String) throws -> [Int] {
        let name = CatalogKey.fold(label)
        guard !name.isEmpty, let number = CatalogKey.catalogNumber(catalogNumber) else {
            return []
        }
        return try database.prepare(
            """
            SELECT release_id FROM catno_keys WHERE label_key = ? AND catno_key = ?
            ORDER BY release_id
            """
        ).map(name, number) { try $0.int(0) }
    }

    /// The masters, and the releases with no master, whose artist and title fold as `artist`
    /// and `title` do: masters first, each in id order.
    func titleMatches(artist: String, title: String) throws -> [TitleMatch] {
        let artistKey = CatalogKey.fold(artist)
        let titleKey = CatalogKey.fold(title, title: true)
        guard !artistKey.isEmpty, !titleKey.isEmpty else { return [] }
        return try database.prepare(
            """
            SELECT DISTINCT master_id, release_id FROM title_keys
            WHERE artist_key = ? AND title_key = ?
            ORDER BY master_id IS NULL, master_id, release_id
            """
        ).map(artistKey, titleKey) { row in
            if let master = row.optionalInt(0) { return .master(master) }
            return .release(try row.int(1))
        }
    }
}

/// Why there's no catalog to read.
public enum CatalogError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    /// Its tables are another build's: it's discarded, and the window offers an import.
    case builtByAnotherVersion(String)

    public var description: String {
        switch self {
        case .missing(let path): "there's no Discogs catalog at \(path); import a dump first"
        case .builtByAnotherVersion(let path):
            "the Discogs catalog at \(path) was built by another version of the app; import"
                + " the dump again"
        }
    }
}
