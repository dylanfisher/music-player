import DisplayText

/// Where an import is, as the window shows it.
public struct CatalogImportProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case reading(DumpKind)
        /// Every file is read and checked; the lookups' indexes are being built.
        case indexing
        case finished
    }

    var stage: Stage
    /// The dump set's date, as its file names have it.
    var dumpDate: String
    /// The compressed bytes read so far, of `totalBytes`.
    public var bytesRead: Int
    var totalBytes: Int
    /// The records imported so far, by dump.
    var records: [DumpKind: Int]

    /// How far the import is, from 0 to 1, by the bytes read: the index build at the end
    /// counts as the last bytes.
    var fraction: Double {
        stage == .finished || totalBytes == 0
            ? 1 : min(1, Double(bytesRead) / Double(totalBytes))
    }

    /// "Importing releases: 1,234,567 so far (42%)", for the window and the log.
    public var text: String {
        let percent = "\(Int(fraction * 100))%"
        switch stage {
        case .reading(let kind):
            return "Importing \(kind.rawValue): \(number(records[kind] ?? 0)) so far (\(percent))"
        case .indexing: return "Building the catalog's indexes (\(percent))"
        case .finished:
            return "Imported the \(dumpDate) dump: "
                + DumpKind.allCases.map { "\(number(records[$0] ?? 0)) \($0.rawValue)" }
                .joined(separator: ", ")
        }
    }
}
