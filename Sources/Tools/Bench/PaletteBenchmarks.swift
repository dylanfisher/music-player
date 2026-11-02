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
]
