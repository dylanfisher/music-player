/// The list an info window on one track was opened from, which its previous and next track
/// buttons step through: how many rows it had then, the row shown, and the path of a row, read
/// from the library, nil for a track no longer in it.
public struct TrackList {
    var count: Int
    var row: Int
    var path: @MainActor (Int) async throws -> String?

    public init(count: Int, row: Int, path: @escaping @MainActor (Int) async throws -> String?) {
        self.count = count
        self.row = row
        self.path = path
    }

    /// Whether there's a row `step` rows from the one shown.
    func canStep(by step: Int) -> Bool { (0..<count).contains(row + step) }
}
