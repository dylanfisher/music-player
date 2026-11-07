import Foundation
import SQLite

/// Writes a new catalog file from the records of a dump set (ADR 0130). Nothing else opens
/// the file while it's written, so it keeps its journal in memory and skips the syncs: a
/// failed import discards the file whole. Belongs to one thread, as its connection does.
final class CatalogWriter {
    /// The page cache while writing, in KiB, as `cache_size` takes a negative number.
    static let cacheKiB = 256 * 1024

    private let database: Database
    private let encoder = JSONEncoder()
    private let insertLabel: Statement
    private let insertArtist: Statement
    private let insertMaster: Statement
    private let insertRelease: Statement
    private let insertTitleKey: Statement
    private let insertBarcodeKey: Statement
    private let insertCatnoKey: Statement

    /// Creates the catalog at `url`, replacing any file there.
    init(creatingAt url: URL) throws {
        try removeDatabase(at: url)
        database = try Database(at: url)
        // `Database` opens a file in WAL mode, which goes to a memory journal only by way of
        // the rollback journal; a catalog with no WAL can be read from a read-only folder. The
        // system SQLite refuses no journal at all (`SQLITE_DBCONFIG_DEFENSIVE`), and a memory
        // journal holds only the pages a transaction changes that were there before it. A
        // sort's temporary files go to disk, not memory, so building an index over millions
        // of keys doesn't hold them all at once.
        try database.execute(
            """
            PRAGMA journal_mode = DELETE; PRAGMA journal_mode = MEMORY; PRAGMA synchronous = OFF;
            PRAGMA cache_size = -\(Self.cacheKiB); PRAGMA temp_store = FILE;
            PRAGMA foreign_keys = OFF
            """)
        let mode = try database.prepare("PRAGMA journal_mode").map { try $0.text(0) }
        guard mode == ["memory"] else {
            throw CatalogImportError.unwritable(url.path, "journal mode \(mode)")
        }
        try database.execute(CatalogSchema.tables)
        insertLabel = try database.prepare("INSERT INTO labels (id, name) VALUES (?, ?)")
        insertArtist = try database.prepare(
            "INSERT INTO artists (id, name, name_variations) VALUES (?, ?, ?)")
        insertMaster = try database.prepare(
            "INSERT INTO masters (id, main_release_id, title, year, lists) VALUES (?, ?, ?, ?, ?)")
        insertRelease = try database.prepare(
            """
            INSERT INTO releases (id, master_id, is_main_release, title, country, released, lists)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
        insertTitleKey = try database.prepare(
            "INSERT INTO title_keys (artist_key, title_key, master_id, release_id) VALUES (?, ?, ?, ?)"
        )
        insertBarcodeKey = try database.prepare(
            "INSERT INTO barcode_keys (barcode_key, release_id) VALUES (?, ?)")
        insertCatnoKey = try database.prepare(
            "INSERT INTO catno_keys (label_key, catno_key, release_id) VALUES (?, ?, ?)")
    }

    /// Writes `records` in one transaction.
    func write(_ records: [DumpRecord]) throws {
        try database.transaction {
            for record in records {
                switch record {
                case .label(let label): try insertLabel.run(label.id, label.name)
                case .artist(let artist):
                    try insertArtist.run(artist.id, artist.name, try json(artist.nameVariations))
                case .master(let master): try add(master)
                case .release(let release): try add(release)
                }
            }
        }
    }

    private func add(_ master: CatalogMaster) throws {
        try insertMaster.run(
            master.id, master.mainReleaseID, master.title, master.year,
            try json(
                CatalogMaster.Lists(
                    artists: master.artists, genres: master.genres, styles: master.styles)))
        try addTitleKeys(artists: master.artists, title: master.title, master: master.id)
    }

    private func add(_ release: CatalogRelease) throws {
        try insertRelease.run(
            release.id, release.masterID, release.isMainRelease, release.title, release.country,
            release.released, try json(release.lists))
        if release.masterID == nil {
            try addTitleKeys(artists: release.artists, title: release.title, release: release.id)
        }
        for barcode in Set(release.barcodes.map(CatalogKey.barcode)) where !barcode.isEmpty {
            try insertBarcodeKey.run(barcode, release.id)
        }
        var numbers: Set<[String]> = []
        for label in release.labels {
            let name = CatalogKey.fold(label.name)
            guard !name.isEmpty, let number = label.catalogNumber.flatMap(CatalogKey.catalogNumber)
            else { continue }
            if numbers.insert([name, number]).inserted {
                try insertCatnoKey.run(name, number, release.id)
            }
        }
    }

    /// The title keys of a master, or of a release with no master, which the matcher looks
    /// albums up by.
    private func addTitleKeys(
        artists: [CatalogArtistCredit], title: String, master: Int? = nil, release: Int? = nil
    ) throws {
        let titleKey = CatalogKey.fold(title, title: true)
        guard !titleKey.isEmpty else { return }
        for artistKey in CatalogKey.artistKeys(artists.map(\.name)).sorted() {
            try insertTitleKey.run(artistKey, titleKey, master, release)
        }
    }

    /// Builds the indexes, and notes the dump the catalog is from.
    func finish(dumpDate: String) throws {
        try database.execute(CatalogSchema.indexes)
        try database.prepare("INSERT INTO catalog (dump_date, schema) VALUES (?, ?)")
            .run(dumpDate, CatalogSchema.identity)
    }

    private func json(_ value: some Encodable) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

/// Removes the database at `url` with its journal and write-ahead log, if any.
func removeDatabase(at url: URL) throws {
    for suffix in ["", Database.walSuffix, Database.shmSuffix, "-journal"] {
        let path = url.path + suffix
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch CocoaError.fileNoSuchFile {
            continue
        }
    }
}
