/// The catalog's tables (ADR 0130). A release's, a master's and an artist's lists are one JSON
/// value in their row, since the catalog is only ever read a record at a time; the folded keys
/// are tables of their own, indexed once every row is in. `import_checkpoint` holds where an
/// unfinished import carries on from (ADR 0134), and the finished import's counts after.
enum CatalogSchema {
    static let tables = """
        CREATE TABLE catalog (dump_date TEXT NOT NULL, schema TEXT NOT NULL);
        CREATE TABLE labels (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
        CREATE TABLE artists (id INTEGER PRIMARY KEY, name TEXT NOT NULL, name_variations TEXT NOT NULL);
        CREATE TABLE masters (
            id INTEGER PRIMARY KEY, main_release_id INTEGER, title TEXT NOT NULL, year INTEGER,
            lists TEXT NOT NULL);
        CREATE TABLE releases (
            id INTEGER PRIMARY KEY, master_id INTEGER, is_main_release INTEGER NOT NULL,
            title TEXT NOT NULL, country TEXT, released TEXT, lists TEXT NOT NULL);
        CREATE TABLE title_keys (
            artist_key TEXT NOT NULL, title_key TEXT NOT NULL, master_id INTEGER,
            release_id INTEGER);
        CREATE TABLE barcode_keys (barcode_key TEXT NOT NULL, release_id INTEGER NOT NULL);
        CREATE TABLE catno_keys (
            label_key TEXT NOT NULL, catno_key TEXT NOT NULL, release_id INTEGER NOT NULL);
        CREATE TABLE import_checkpoint (checkpoint TEXT NOT NULL, sha256 TEXT NOT NULL);
        """

    /// Built after the last row, which sorts each once instead of inserting into it in key
    /// order row by row.
    static let indexes = """
        CREATE INDEX releases_by_master ON releases (master_id) WHERE master_id IS NOT NULL;
        CREATE INDEX title_keys_by_key ON title_keys (artist_key, title_key);
        CREATE INDEX barcode_keys_by_key ON barcode_keys (barcode_key);
        CREATE INDEX catno_keys_by_key ON catno_keys (label_key, catno_key);
        """

    /// What a catalog records it was built with: a catalog built with any other is discarded
    /// and imported again.
    static let identity = tables + indexes
}
