/// A file's spectrogram, reduced to at most `maximumColumns` time columns of `rows`
/// frequency rows, each cell the loudest any FFT frame and bin in it reached, so a short
/// event survives the reduction; and the average spectrum in the same rows.
public struct Spectrogram: Equatable, Sendable {
    static let maximumColumns = 1000
    public static let rows = 512
    /// The level a cell's 0 stands for; 255 is 0 dB, a full-scale sine. Lower levels are 0.
    public static let floorDB = -150.0

    public var columns: Int
    /// `columns × rows` levels, column after column, each from the lowest row up, as 8 bits
    /// from `floorDB` to 0 dB.
    public var cells: [UInt8]
    /// Each row's level averaged over the file, in dB.
    public var averageDB: [Float]
    /// The top of the highest row.
    public var nyquistHz: Double
    public var durationSeconds: Double

    init(
        columns: Int, cells: [UInt8], averageDB: [Float], nyquistHz: Double,
        durationSeconds: Double
    ) {
        precondition(cells.count == columns * Self.rows, "a spectrogram's cells fill its grid")
        precondition(averageDB.count == Self.rows, "an average spectrum has a level per row")
        self.columns = columns
        self.cells = cells
        self.averageDB = averageDB
        self.nyquistHz = nyquistHz
        self.durationSeconds = durationSeconds
    }

    /// The cell's level in dB: `floorDB` or below for 0.
    public func level(column: Int, row: Int) -> Double {
        Self.decibels(cells[column * Self.rows + row])
    }

    static func decibels(_ cell: UInt8) -> Double {
        Self.floorDB * (1 - Double(cell) / 255)
    }

    static func cell(_ decibels: Double) -> UInt8 {
        UInt8(min(255, max(0, (255 * (1 - decibels / Self.floorDB)).rounded())))
    }

    /// The frequency in the middle of `row`.
    func frequencyHz(row: Int) -> Double {
        (Double(row) + 0.5) * nyquistHz / Double(Self.rows)
    }
}
