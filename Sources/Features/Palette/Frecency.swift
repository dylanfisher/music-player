import Foundation
import Settings

/// Frecency as zoxide weighs it: the visit count times 4 within the hour, 2 within the day, 1/2
/// within the week and 1/4 before. Counted from palette choices and from plays.
public struct Frecency: Sendable, Equatable {
    public private(set) var log: VisitLog

    public init(_ log: VisitLog) {
        self.log = log
    }

    /// Counts a visit to `key` at `now`. Past the log's capacity the least frecent goes.
    public mutating func record(_ key: String, now: Double) {
        var visits = log.visits
        let index = visits.partitioningIndex { $0.key >= key }
        if index < visits.count, visits[index].key == key {
            visits[index].count += 1
            visits[index].lastSeconds = now
        } else {
            visits.insert(VisitLog.Visit(key: key, count: 1, lastSeconds: now), at: index)
        }
        if visits.count > VisitLog.capacity {
            let least = visits.indices.filter { visits[$0].key != key }
                .min { Self.score(visits[$0], now) < Self.score(visits[$1], now) }!
            visits.remove(at: least)
        }
        log = VisitLog(visits: visits)
    }

    /// Every key's frecency at `now`.
    func scores(now: Double) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: log.visits.map { ($0.key, Self.score($0, now)) })
    }

    static func score(_ visit: VisitLog.Visit, _ now: Double) -> Double {
        let age = now - visit.lastSeconds
        let weight: Double =
            age < 3600 ? 4 : age < 86_400 ? 2 : age < 604_800 ? 0.5 : 0.25
        return Double(visit.count) * weight
    }

    /// The bonus a frecency adds to a match: the whole part of its log2, from 0 below 2 up to 4
    /// at 16 and over. Smaller than one letter's run bonus, so it reorders near-ties only.
    static func bonus(_ frecency: Double) -> Int {
        frecency < 2 ? 0 : min(4, Int(log2(frecency)))
    }
}

extension Array {
    /// The first index whose element `belongs` says is in the second part of a partitioned
    /// array, found by binary search.
    fileprivate func partitioningIndex(where belongs: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if belongs(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
