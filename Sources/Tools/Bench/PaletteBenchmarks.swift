import Foundation
import Library
import Palette

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
    }
]
