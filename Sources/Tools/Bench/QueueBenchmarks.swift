import AppKit
import Foundation
import Library
import Playback
import QueueView

/// How many track changes the queue benchmark times.
private let trackChanges = 60

let queueBenchmarks = [
    Benchmark(
        name: "queue: track change with the whole library queued, panel open (p95)",
        budget: Budget(appleSilicon: 8, oldMac: 16, unit: .milliseconds)
    ) {
        let library = try scannedLibrary.get()
        let samples = try onMainActor {
            let index = try LibraryIndex(at: library.databaseURL)
            let ids = try index.trackIDs(sortedBy: .artist)
            let paths = try index.paths(ids: ids)
            var state = PlaybackState()
            state.queue = ids.compactMap { paths[$0] }.map {
                URL(fileURLWithPath: $0, isDirectory: false)
            }
            state.order = Array(state.queue.indices)
            let panel = QueuePanel(model: QueueModel { try index.track(path: $0) })
            // As tall as the 2015 MacBook Pro's screen, the panel's default width.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 800), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.contentView = panel.view
            var samples: [Double] = []
            for step in 0..<trackChanges {
                state.currentIndex = state.queue.count / 2 + step
                let start = DispatchTime.now().uptimeNanoseconds
                panel.show(state)
                window.displayIfNeeded()
                CATransaction.flush()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            return Array(samples.dropFirst())
        }
        return Measured(
            value: p95(samples),
            notes: ["\(samples.count) track changes, Next after Next; " + slowestNote(samples)])
    }
]
