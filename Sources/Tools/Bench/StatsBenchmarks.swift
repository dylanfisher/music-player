import Foundation
import Library
import Settings

let statsBenchmarks = [
    Benchmark(
        name: "stats: open Stats on This Month, 1M synthetic plays (p95)",
        budget: Budget(appleSilicon: 400, oldMac: 1500, unit: .milliseconds)
    ) {
        let url = try playedLibrary.get().databaseURL
        var plays = 0
        // Opening is a new connection, every album's first play and the period's report.
        let samples = try millisecondSamples(
            (0..<10).map { _ in
                {
                    plays = try blocking {
                        try await StatsReader(databaseURL: url).report(
                            .month, groupByAlbumArtist: false
                        ).plays
                    }
                }
            })
        return Measured(
            value: p95(samples), notes: [slowestNote(samples), "\(plays) plays this month"])
    },
    Benchmark(
        name: "stats: change the period, each in turn, 1M synthetic plays (p95)",
        budget: Budget(appleSilicon: 250, oldMac: 900, unit: .milliseconds)
    ) {
        let reader = try StatsReader(databaseURL: try playedLibrary.get().databaseURL)
        _ = try blocking { try await reader.report(.month, groupByAlbumArtist: false) }
        let lastYear = Calendar.current.component(.year, from: Date()) - 1
        let periods: [StatsPeriod] = [.week, .month, .year, .chosenYear(lastYear), .all]
        var times: [StatsPeriod: [Double]] = [:]
        for _ in 0..<4 {
            for period in periods {
                times[period, default: []] += try millisecondSamples([
                    {
                        _ = try blocking {
                            try await reader.report(period, groupByAlbumArtist: false)
                        }
                    }
                ])
            }
        }
        let samples = times.values.flatMap { $0 }
        return Measured(
            value: p95(samples),
            notes: [
                periods.map { period in
                    String(format: "%@ %.0f ms", period.title, p95(times[period] ?? []))
                }.joined(separator: ", ")
            ])
    },
]

/// Waits for `body` on this thread, for a benchmark of an actor's work.
private func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let result = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            result.set(.success(try await body()))
        } catch {
            result.set(.failure(error))
        }
        done.signal()
    }
    done.wait()
    return try result.get()
}

/// Hands a result from a task to the thread waiting for it.
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    // `result` is guarded by `lock`.
    private let lock = NSLock()
    private var result: Result<T, any Error>?

    func set(_ value: Result<T, any Error>) { lock.withLock { result = value } }

    func get() throws -> T {
        guard let result = lock.withLock({ result }) else {
            throw BenchError.expected("a result")
        }
        return try result.get()
    }
}
