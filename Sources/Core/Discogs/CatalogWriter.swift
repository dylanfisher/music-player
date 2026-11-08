import Foundation
import SQLite

/// Writes a new catalog file from the records of a dump set (ADR 0130). Nothing else writes
/// the file while it's built, so it skips the syncs. Its rows are committed only with a
/// checkpoint (ADR 0134), in one transaction from each checkpoint to the next, so the rows
/// always match the checkpoint a resume starts from. Belongs to one thread, as its connection
/// does.
final class CatalogWriter {
    /// The page cache while writing, in KiB, as `cache_size` takes a negative number.
    static let cacheKiB = 256 * 1024

    private let database: Database
    /// Keys in order, so an import resumed partway writes the rows one straight through does.
    private let encoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
    private let insertLabel: Statement
    private let insertArtist: Statement
    private let insertMaster: Statement
    private let insertRelease: Statement
    private let insertTitleKey: Statement
    private let insertBarcodeKey: Statement
    private let insertCatnoKey: Statement

    /// Creates the catalog at `url`, replacing any file there, with its tables and `checkpoint`.
    convenience init(creatingAt url: URL, checkpoint: ImportCheckpoint) throws {
        try removeDatabase(at: url)
        try self.init(at: url, creating: checkpoint)
    }

    /// Opens the unfinished catalog at `url` to write on from its checkpoint. A transaction a
    /// killed import left open is rolled back as the file opens.
    convenience init(resumingAt url: URL) throws {
        try self.init(at: url, creating: nil)
    }

    private init(at url: URL, creating checkpoint: ImportCheckpoint?) throws {
        // A rollback journal on disk, not WAL, which would write every page twice, nor a memory
        // journal, which a killed process takes with it, leaving a transaction half written.
        // The journal holds only the pages a transaction changes that were there before it,
        // which are few while rows are appended. A catalog with no WAL can be read from a
        // read-only folder. A sort's temporary files go to disk, not memory, so building an
        // index over millions of keys doesn't hold them all at once.
        let database = try Database(rollbackJournalAt: url, creating: checkpoint != nil)
        self.database = database
        try database.execute(
            """
            PRAGMA synchronous = OFF; PRAGMA cache_size = -\(Self.cacheKiB);
            PRAGMA temp_store = FILE; PRAGMA foreign_keys = OFF
            """)
        if let checkpoint {
            try database.transaction {
                try database.execute(CatalogSchema.tables)
                try checkpoint.write(to: database)
            }
        }
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
        try database.execute("BEGIN")
    }

    /// Writes `records` in the transaction open, which the next checkpoint commits.
    func write(_ records: [DumpRecord]) throws {
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

    /// Commits the rows written since the last checkpoint with `checkpoint`, which covers them.
    func commit(_ checkpoint: ImportCheckpoint) throws {
        try checkpoint.write(to: database)
        try database.execute("COMMIT; BEGIN")
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
        if let master = release.masterID {
            // A release can print a name its master doesn't, which finds the master too.
            try addTitleKeys(
                artists: release.artists, title: release.title, master: master,
                variationsOnly: true)
        } else {
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
    /// albums up by: the artists by name and by the name variations (ANVs) the record prints,
    /// as an album may be tagged with either. `variationsOnly` leaves out the keys of the
    /// names, as for a release whose master has them.
    private func addTitleKeys(
        artists: [CatalogArtistCredit], title: String, master: Int? = nil, release: Int? = nil,
        variationsOnly: Bool = false
    ) throws {
        let titleKey = CatalogKey.fold(title, title: true)
        guard !titleKey.isEmpty else { return }
        let names = CatalogKey.artistKeys(artists.map(\.name))
        let variations = CatalogKey.artistKeys(artists.map { $0.nameVariation ?? $0.name })
        let keys = variationsOnly ? variations.subtracting(names) : names.union(variations)
        for artistKey in keys.sorted() {
            try insertTitleKey.run(artistKey, titleKey, master, release)
        }
    }

    /// Builds the indexes, notes the dump the catalog is from, and commits them with
    /// `checkpoint`, the last.
    func finish(_ checkpoint: ImportCheckpoint) throws {
        precondition(checkpoint.indexed, "the last checkpoint says the indexes are built")
        try database.execute(CatalogSchema.indexes)
        try database.prepare("INSERT INTO catalog (dump_date, schema) VALUES (?, ?)")
            .run(checkpoint.dumpDate, CatalogSchema.identity)
        try checkpoint.write(to: database)
        try database.execute("COMMIT")
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
