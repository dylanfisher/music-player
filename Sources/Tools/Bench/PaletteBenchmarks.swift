import Foundation
import Library
import Palette
import Settings

let paletteBenchmarks = [
    Benchmark(
        name: "palette: Go to Item keystroke over every fixture track (p95)",
        budget: Budget(appleSilicon: 15, oldMac: 80, unit: .milliseconds)
    ) {
        let index = try scannedLibrary.get().index
        let names = try index.trackNames(sortedBy: .artist)
        var items: [PaletteItem] = []
        let prepareSeconds = seconds {
            items = names.map { name in
                PaletteItem(
                    kind: .track, key: "track:\(name.id)", title: name.title,
                    detail: name.artist)
            }
        }
        // Each of ten titles from across the list, typed a letter at a time.
        let step = max(1, names.count / 10)
        let typed = stride(from: 0, to: names.count, by: step).prefix(10).flatMap { row in
            let title = names[row].title
            return title.indices.map { String(title[...$0]) }
        }
        let samples = try millisecondSamples(
            typed.map { query in
                {
                    _ = rankPalette(
                        items, query: query, frecency: [:], limit: PaletteModel.limit, byKind: true)
                }
            })
        return Measured(
            value: p95(samples),
            notes: [
                "\(items.count) rows, \(samples.count) keystrokes; preparing the rows took"
                    + String(format: " %.0f ms, off the main actor", prepareSeconds * 1000)
            ])
    },
    Benchmark(
        name: "palette: Go to Item's opening rows over every fixture track, on the main actor",
        budget: Budget(appleSilicon: 4, oldMac: 16, unit: .milliseconds)
    ) {
        let names = try scannedLibrary.get().index.trackNames(sortedBy: .artist)
        let items = names.map { name in
            PaletteItem(kind: .track, key: "track:\(name.id)", title: name.title)
        }
        // A full frecency log, so each row costs the lookup it does in use.
        let frecency = Dictionary(
            uniqueKeysWithValues: (0..<VisitLog.capacity).map { ("artist:\($0)", Double($0)) })
        // The palette lists these before its panel shows, so the old Mac's budget is one frame.
        let value = try medianMilliseconds(iterations: 20) {
            _ = rankPalette(
                items, query: "", frecency: frecency, limit: PaletteModel.limit, byKind: true)
        }
        return Measured(value: value, notes: ["\(items.count) rows, median of 20"])
    },
    Benchmark(
        name: "palette: Go to Item, the last of 8 keystrokes 50 ms apart to its results (median)",
        budget: Budget(appleSilicon: 15, oldMac: 80, unit: .milliseconds)
    ) {
        let bursts = try paletteBursts.get()
        let last = bursts.map(\.lastResultMs).sorted()
        let cpu = bursts.map(\.cpuMs).sorted()
        return Measured(
            value: last[last.count / 2],
            notes: [
                "\(bursts.count) bursts, each "
                    + bursts.map { String(format: "%.1f ms", $0.lastResultMs) }.joined(
                        separator: ", "),
                "CPU per burst, every ranking included: "
                    + cpu.map { String(format: "%.0f ms", $0) }.joined(separator: ", "),
            ])
    },
]

/// Keystrokes in one burst, and the time between them: a fast typist.
private let burstKeystrokes = 8
private let burstIntervalSeconds = 0.05
/// How long after the burst's last result the rankings it dropped get to finish, so their CPU
/// is counted.
private let burstSettleSeconds = 1.0

/// What one burst of keystrokes cost: from the last keystroke to its results, and the CPU the
/// process used from the first keystroke until every ranking ended.
private struct Burst: Sendable {
    var lastResultMs: Double
    var cpuMs: Double
}

/// Types the first `burstKeystrokes` letters of titles from across the list into Go to Item over
/// every fixture track, `burstIntervalSeconds` apart, as the palette's field sends them.
private let paletteBursts = Result { () throws -> [Burst] in
    let names = try scannedLibrary.get().index.trackNames(sortedBy: .artist)
    let items = names.map { name in
        PaletteItem(kind: .track, key: "track:\(name.id)", title: name.title)
    }
    let titles = stride(from: 0, to: names.count, by: names.count / 7).map { names[$0].title }
        .filter { $0.count >= burstKeystrokes }
    guard titles.count >= 3 else {
        throw BenchError.expected("titles of \(burstKeystrokes) letters or more")
    }
    return try onMainActor {
        var bursts: [Burst] = []
        for title in titles {
            let model = PaletteModel(frecency: Frecency(VisitLog(visits: [])))
            _ = model.open(items, byKind: true)
            let typed = (1...burstKeystrokes).map { String(title.prefix($0)) }
            let cpuStart = processCPUSeconds()
            for query in typed.dropLast() {
                Task { await model.setQuery(query) }
                try await Task.sleep(nanoseconds: UInt64(burstIntervalSeconds * 1e9))
            }
            let start = DispatchTime.now().uptimeNanoseconds
            await model.setQuery(typed.last!)
            let lastResultMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            guard model.query == typed.last, !model.results.isEmpty else {
                throw BenchError.expected("results for \"\(typed.last!)\"")
            }
            try await Task.sleep(nanoseconds: UInt64(burstSettleSeconds * 1e9))
            bursts.append(
                Burst(lastResultMs: lastResultMs, cpuMs: (processCPUSeconds() - cpuStart) * 1000))
        }
        return bursts
    }
}

/// The CPU time every thread of this process has used.
private func processCPUSeconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)) / 1e9
}
