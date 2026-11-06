/// Where an average spectrum falls steeply and stays down, and how fast it falls there.
struct Cutoff: Equatable {
    var frequencyHz: Double
    var steepnessDBPerKHz: Double

    /// The highest frequency, from `AnalysisRules.cutoffSearchFromHz` up, where the mean level
    /// over the half span above is `AnalysisRules.cutoffDropDB` or more under the mean over the
    /// half span below; nil when the spectrum has no such fall. `rowDB` is the level of rows
    /// `rowHz` wide, from 0 Hz up.
    init?(rowDB: [Double], rowHz: Double) {
        let half = max(2, Int((AnalysisRules.cutoffSpanHz / 2 / rowHz).rounded()))
        let lowest = max(half, Int((AnalysisRules.cutoffSearchFromHz / rowHz).rounded(.up)))
        let highest = rowDB.count - half
        guard highest >= lowest else { return nil }
        // The fall from the rows under `edge` to the rows from it up.
        func fall(_ edge: Int) -> Double {
            mean(rowDB[edge - half..<edge]) - mean(rowDB[edge..<edge + half])
        }
        guard
            let first = stride(from: highest, through: lowest, by: -1).first(where: {
                fall($0) >= AnalysisRules.cutoffDropDB
            })
        else { return nil }
        // Coming down from above, the fall first passes the threshold before the edge; the
        // edge is where it's largest, at most half a span lower.
        let edge = (max(lowest, first - half)...first).max { fall($0) < fall($1) }!
        frequencyHz = Double(edge) * rowHz
        steepnessDBPerKHz = fall(edge) / (Double(half) * rowHz / 1000)
    }
}

private func mean(_ values: ArraySlice<Double>) -> Double {
    values.reduce(0, +) / Double(values.count)
}
