import Foundation
import LibraryBrowser
import Settings

/// The app scrolling its track table in trackpad flicks, a frame at a time, as the owner scrolls
/// the library on the 2015 MacBook Pro (ADR 0073). Each case is one launch, cached for the
/// benchmarks that read it.
let scrollBenchmarks = [
    Benchmark(
        name: "window: trackpad scroll with art, main thread per frame (p95)",
        budget: Budget(appleSilicon: 16, oldMac: 33, unit: .milliseconds)
    ) {
        try framesMeasured(try trackpadScroll.get())
    },
    Benchmark(
        name: "window: trackpad scroll, compact rows and a wide art column, per frame (p95)",
        budget: Budget(appleSilicon: 16, oldMac: 33, unit: .milliseconds)
    ) {
        try framesMeasured(try wideArtScroll.get())
    },
    Benchmark(
        name: "window: trackpad scroll by title with art on a slow simulated NAS, per frame (p95)",
        budget: Budget(appleSilicon: 16, oldMac: 33, unit: .milliseconds)
    ) {
        try framesMeasured(try nasScroll.get())
    },
    Benchmark(
        name:
            "window: page down the art column by title, art on a slow simulated NAS, after a relaunch",
        budget: Budget(appleSilicon: 1, oldMac: 3, unit: .seconds)
    ) {
        let launches = try pagedLaunches.get()
        let waits = launches.map { $0.pageCoversMs.reduce(0, +) / 1000 }
        return Measured(
            value: waits[1],
            notes: [
                "the covers of \(launches[1].pageCoversMs.count) screens; after the first launch"
                    + String(format: " %.2f s", waits[0])
                    + "; art reads \(launches[0].artReads), then \(launches[1].artReads)"
            ])
    },
    Benchmark(
        name:
            "window: last cover on screen after a page down by title, art on a slow simulated NAS",
        budget: Budget(appleSilicon: 250, oldMac: 500, unit: .milliseconds)
    ) {
        let report = try nasScroll.get()
        guard let lastCoverMs = report.lastCoverMs else {
            throw BenchError.expected("the covers on screen to arrive")
        }
        return Measured(
            value: lastCoverMs,
            notes: [
                String(
                    format: "%.0f ms an art read; %d reads", nasArtReadSeconds * 1e3,
                    report.artReads)
            ])
    },
    Benchmark(
        name: "window: trackpad scroll while a scan refreshes the list, a refresh's frame (median)",
        budget: Budget(appleSilicon: 16, oldMac: 33, unit: .milliseconds)
    ) {
        let report = try scanScroll.get()
        // The median, since every refresh costs about the same and one frame in a few can
        // wait on the window server for tens of milliseconds on a busy machine.
        let frames = report.refreshFramesMs.sorted()
        guard !frames.isEmpty else {
            throw BenchError.expected("the list to refresh during the scroll")
        }
        var measured = try framesMeasured(report)
        measured.value = frames[frames.count / 2]
        measured.notes.append(
            "each refresh's frame "
                + report.refreshFramesMs.map { String(format: "%.1f ms", $0) }.joined(
                    separator: ", "))
        return measured
    },
    Benchmark(
        name: "window: live resize of the window and the art column, per frame (p95)",
        budget: Budget(appleSilicon: 16, oldMac: 33, unit: .milliseconds)
    ) {
        try framesMeasured(try resizeScroll.get())
    },
    Benchmark(
        name: "window: a row height change with the art column, its frame (median)",
        budget: Budget(appleSilicon: 50, oldMac: 150, unit: .milliseconds)
    ) {
        let frames = try resizeScroll.get().refreshFramesMs.sorted()
        guard !frames.isEmpty else { throw BenchError.expected("the row height to change") }
        return Measured(
            value: frames[frames.count / 2],
            notes: [
                "\(frames.count) changes; " + slowestNote(frames)
            ])
    },
]

/// An art read on the slow simulated NAS: opening, one read and closing, each an operation, and
/// the median wait on its disks.
let nasArtReadSeconds =
    3 * slowNAS.operationSeconds + (slowNAS.fileDelay?.medianSeconds ?? 0)

/// The table as it opens with the Album Art column added.
private let trackpadScroll = Result {
    try scroll(.trackpad, artColumnWidth: TrackColumn.art.defaultWidth)
}
/// Compact rows under a 256-point art column, so a cover spans about 15 rows and the fixture
/// albums of 15 to 24 tracks run past it.
private let wideArtScroll = Result {
    try scroll(.trackpad, artColumnWidth: 256, rowHeight: .compact)
}
/// Sorted by title, so nearly every row is an album's run of its own and asks for its art.
private let nasScroll = Result {
    try scroll(
        .trackpad, artColumnWidth: TrackColumn.art.defaultWidth, sortColumn: .title,
        artDelaySeconds: nasArtReadSeconds)
}
private let scanScroll = Result {
    try scroll(.scan, artColumnWidth: TrackColumn.art.defaultWidth)
}
private let resizeScroll = Result {
    try scroll(.resize, artColumnWidth: TrackColumn.art.defaultWidth)
}
/// Paging by title on the slow simulated NAS, launched twice on one home: once as after an
/// install, then as every later launch is.
private let pagedLaunches = Result { () throws -> [ScrollReport] in
    let app = try appExecutable()
    return try withIndexedHome(
        artColumnWidth: TrackColumn.art.defaultWidth, sortColumn: .title
    ) { home in
        try (0..<2).map { _ in
            try JSONDecoder().decode(
                ScrollReport.self,
                from: try runMeasuring(
                    app, home: home, scrollArguments(.pages, artDelaySeconds: nasArtReadSeconds)))
        }
    }
}

private func scroll(
    _ scrollCase: ScrollCase, artColumnWidth: Double, rowHeight: RowHeight? = nil,
    sortColumn: TrackColumn? = nil, artDelaySeconds: Double = 0
) throws -> ScrollReport {
    let app = try appExecutable()
    return try withIndexedHome(
        artColumnWidth: artColumnWidth, rowHeight: rowHeight, sortColumn: sortColumn
    ) { home in
        try JSONDecoder().decode(
            ScrollReport.self,
            from: try runMeasuring(
                app, home: home, scrollArguments(scrollCase, artDelaySeconds: artDelaySeconds)))
    }
}

private func scrollArguments(_ scrollCase: ScrollCase, artDelaySeconds: Double) -> [String] {
    var arguments = ["--measure-scroll", scrollCase.rawValue]
    if artDelaySeconds > 0 {
        arguments += ["--art-delay-ms", String(format: "%.0f", artDelaySeconds * 1e3)]
    }
    return arguments
}

/// The p95 of the frames, with the worst frame, the frame count and the art reads in the notes.
private func framesMeasured(_ report: ScrollReport) throws -> Measured {
    guard !report.framesMs.isEmpty else { throw BenchError.expected("the table to scroll") }
    return Measured(
        value: p95(report.framesMs),
        notes: [
            "\(report.framesMs.count) frames; " + slowestNote(report.framesMs)
                + "; \(report.artReads) art reads"
                + (report.lastCoverMs.map { String(format: "; last cover %.0f ms", $0) } ?? "")
        ])
}
