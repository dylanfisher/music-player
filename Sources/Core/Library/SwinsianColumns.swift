import Foundation
import Metadata
import Settings

/// Swinsian's track table as its preferences file describes it, mapped to ours: the visible
/// columns left to right with their widths, and the sort (ADR 0055). The file is only read.
public struct SwinsianColumns: Equatable, Sendable {
    /// Where Swinsian keeps its preferences, columns included.
    public static let preferencesURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
            "Library/Preferences/com.swinsian.Swinsian.plist", isDirectory: false)
    /// The owner's is 15 KB.
    static let maximumBytes = 4 << 20
    /// The sort's archive; the owner's is under 400 bytes.
    static let maximumSortBytes = 64 << 10
    /// More than Swinsian has columns; entries past it aren't read.
    static let maximumColumns = 200

    /// The preferences' keys, as the owner's file had them on 2026-11-02. The visible
    /// columns: a list of dictionaries of an ID and a width.
    package static let columnsKey = "MainTableColumns-Ver1"
    package static let columnIDKey = "TableColumnIdentifier"
    package static let columnWidthKey = "TableColumnWidth"
    /// The sort: an `NSKeyedArchiver` archive of a list of dictionaries of a column's ID and
    /// whether it's ascending, as `NSTableView` saves it.
    package static let sortKey = "NSTableView Sort Ordering v2 main_track_table"
    package static let sortIDKey = "Identifier"
    package static let sortAscendingKey = "Ascending"

    /// Swinsian's column IDs and ours: the columns named alike, then the others. Only IDs seen
    /// in the owner's preferences are listed; any other is skipped and reported.
    static let columnIDs: [String: TrackColumn] = Dictionary(
        uniqueKeysWithValues: [
            TrackColumn.title, .artist, .album, .albumArtist, .composer, .conductor, .lyricist,
            .grouping, .work, .movementName, .genre, .year, .trackNumber, .discSubtitle, .bpm,
            .fileType, .bitRate, .sampleRate, .bitDepth, .channels, .fileName, .path, .dateAdded,
            .dateCreated, .dateModified, .playCount, .lastPlayed, .rating, .publisher,
            .catalogNumber, .barcode, .copyright, .encoder, .comment,
        ].map { ($0.rawValue, $0) }
    ).merging(
        [
            "artwork": .art, "movement": .movementNumber, "originalReleaseDate": .originalDate,
            "totalNumberOfTracks": .trackTotal, "trackNumbers": .trackOfTotal,
            "disc": .discNumber, "totalNumberOfDiscs": .discTotal,
            "discNumbersString": .discOfTotal, "length": .duration, "initialKey": .key,
            "fileSize": .size, "favourite": .loved, "descriptionTag": .description,
        ], uniquingKeysWith: { _, renamed in renamed })

    /// The preferences file's path.
    public let source: String
    /// The columns that map, in Swinsian's order. Never empty.
    public var columns: [ColumnLayout] = []
    /// Nil when Swinsian keeps no sort or sorts by a column that doesn't map.
    public var sortColumn: TrackColumn?
    public var sortAscending = true
    /// What wasn't brought across and why, one line each.
    public var skipped: [String] = []

    /// Reads the file at `url` without following a link, and only if it's a regular file under
    /// `maximumBytes`.
    public init(preferencesAt url: URL) throws {
        let source: FileSource
        do throws(ParseFailure) {
            source = try FileSource(path: url.path, hints: .none)
        } catch {
            throw PlayerImportError.unreadable(error.detail)
        }
        guard source.size <= Self.maximumBytes else {
            throw PlayerImportError.tooLarge(source.size, maximum: Self.maximumBytes)
        }
        let data: Data
        do throws(ParseFailure) {
            data = try source.readData(0..<source.size)
        } catch {
            throw PlayerImportError.unreadable(error.detail)
        }
        try self.init(preferences: data, source: url.path)
    }

    init(preferences data: Data, source: String) throws(PlayerImportError) {
        self.source = source
        let root = try propertyListRoot(data, refused: PlayerImportError.notPreferences)
        guard let entries = root[Self.columnsKey] as? [Any] else {
            throw .notPreferences("it has no \(Self.columnsKey) list")
        }
        readColumns(entries)
        guard !columns.isEmpty else { throw .noColumns }
        readSort(root[Self.sortKey])
    }

    /// The table with these columns, and this sort or, when there's none, `current`'s.
    public func layout(over current: TrackTableLayout) -> TrackTableLayout {
        TrackTableLayout(
            columns: columns, sortColumn: sortColumn ?? current.sortColumn,
            sortAscending: sortColumn == nil ? current.sortAscending : sortAscending)
    }

    private mutating func readColumns(_ entries: [Any]) {
        let range = TrackTableLayout.widthRange
        for (place, entry) in entries.prefix(Self.maximumColumns).enumerated() {
            guard let fields = entry as? [String: Any],
                let id = fields[Self.columnIDKey] as? String
            else {
                skipped.append("column \(place + 1): has no identifier")
                continue
            }
            guard let column = Self.columnIDs[id] else {
                skipped.append("\(id): no such column here")
                continue
            }
            guard !columns.contains(where: { $0.column == column }) else {
                skipped.append("\(id): listed twice")
                continue
            }
            guard let width = (fields[Self.columnWidthKey] as? NSNumber)?.doubleValue else {
                skipped.append("\(id): has no width")
                continue
            }
            guard range.contains(width) else {
                skipped.append(
                    "\(id): its width \(width) is outside \(range.lowerBound)...\(range.upperBound)"
                )
                continue
            }
            columns.append(ColumnLayout(column: column, width: width))
        }
        if entries.count > Self.maximumColumns {
            skipped.append(
                "\(entries.count - Self.maximumColumns) columns past the first"
                    + " \(Self.maximumColumns)")
        }
    }

    private mutating func readSort(_ value: Any?) {
        guard let value else {
            skipped.append("sort: Swinsian keeps none, so the table's sort stays")
            return
        }
        guard let (id, ascending) = Self.firstSortKey(value) else {
            skipped.append("sort: couldn't be read, so the table's sort stays")
            return
        }
        guard let column = Self.columnIDs[id], column.isSortable else {
            skipped.append("sort by \(id): no such column here, so the table's sort stays")
            return
        }
        sortColumn = column
        sortAscending = ascending
    }

    /// The first sort key in the archive. Its objects are read by number from the property
    /// list, as the smart playlists' are, never by `NSKeyedUnarchiver` (ADR 0033); every
    /// reference is checked before it's followed, and nothing is followed more than three deep.
    private static func firstSortKey(_ value: Any) -> (String, Bool)? {
        guard let data = value as? Data, data.count <= maximumSortBytes,
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let (objects, roots) = SwinsianArchive.objectTable(plist), roots.count == 1
        else { return nil }
        func object(_ reference: Any?) -> Any? {
            guard let reference, let number = SwinsianArchive.objectNumber(reference),
                number >= 1, number < objects.count
            else { return nil }
            return objects[number]
        }
        guard let array = object(roots.values.first) as? [String: Any],
            let first = (array[SwinsianArchive.itemsKey] as? [Any])?.first,
            let dictionary = object(first) as? [String: Any],
            let keys = dictionary["NS.keys"] as? [Any],
            let values = dictionary[SwinsianArchive.itemsKey] as? [Any],
            keys.count == values.count
        else { return nil }
        var fields: [String: Any] = [:]
        for (key, value) in zip(keys, values) {
            guard let key = object(key) as? String, let value = object(value) else { return nil }
            fields[key] = value
        }
        guard let id = fields[sortIDKey] as? String,
            let ascending = fields[sortAscendingKey] as? NSNumber
        else { return nil }
        return (id, ascending.boolValue)
    }
}
