import Library

/// The Lost Stats sheet's state: the lost files left to resolve, shown one at a time, and the
/// paths of their candidates. Each pick or dismissal is written before the next file shows.
@MainActor
final class LostStatsSession {
    private(set) var lost: [LostFile]
    /// The candidates' paths, by track ID.
    let paths: [Int64: String]
    /// False when the pick went stale since the list was read.
    private let move: (_ lost: Int64, _ track: Int64) async throws -> Bool
    private let dismiss: ([Int64]) async throws -> Void

    init(
        lost: [LostFile], paths: [Int64: String],
        move: @escaping (_ lost: Int64, _ track: Int64) async throws -> Bool,
        dismiss: @escaping ([Int64]) async throws -> Void
    ) {
        self.lost = lost
        self.paths = paths
        self.move = move
        self.dismiss = dismiss
    }

    /// The file shown, or nil once every one is resolved.
    var current: LostFile? { lost.first }

    /// Gives the shown file's stats to `track`, one of its candidates. The track has stats now,
    /// so it's no longer a candidate for the others. A pick a scan made stale since the list
    /// was read (the file came back, or the track was played) changes nothing, and the next
    /// file shows as after any other.
    func pick(_ track: Int64) async throws {
        guard let file = current, file.candidates.contains(track) else {
            preconditionFailure("track \(track) isn't a candidate of the file shown")
        }
        let moved = try await move(file.id, track)
        lost.removeFirst()
        guard moved else { return }
        for index in lost.indices where lost[index].candidates.contains(track) {
            lost[index].candidates.removeAll { $0 == track }
            lost[index].matching -= 1
        }
    }

    /// Takes the shown file out of Lost Stats.
    func dismissShown() async throws {
        guard let file = current else { preconditionFailure("no lost file is shown") }
        try await dismiss([file.id])
        lost.removeFirst()
    }
}
