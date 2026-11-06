import Analysis
import DisplayText
import Foundation
import Library

/// The Spectrum window's files and what it draws from them, with no AppKit (ADR 0115): each
/// file's progress, result or error, the frequency axis they share, the reference lines and
/// the text under the pointer.
@MainActor
public final class SpectrumModel {
    public typealias Analyze =
        @Sendable (_ path: String, _ progress: @escaping @Sendable (Double) -> Void) async throws ->
        AnalysisResult

    public enum State: Equatable {
        case waiting
        /// The share read so far.
        case analyzing(Double)
        case analyzed(AnalysisResult)
        case failed(String)
    }

    public struct File: Equatable {
        public var path: String
        public var title: String
        var album: String?
        /// As the index has it; nil for a file it doesn't.
        var sizeBytes: Int?
        /// The extension, uppercased, as `TrackRow.fileType`: what tells two files of one
        /// title apart.
        var fileType: String
        public var state: State = .waiting
    }

    /// Frequencies lossy encoders and sample rates stop at, drawn as dotted lines.
    static let referenceHz = [16_000.0, 19_000, 20_000, cdNyquistHz, 24_000]
    /// A CD's Nyquist frequency: a reference line, and the axis's top before any file is analyzed.
    static let cdNyquistHz = 22_050.0
    /// Files analyzed at once: two, so a second file's reads overlap the first's FFTs without
    /// taking every core of the 2015 MacBook Pro while music plays.
    static let filesAtOnce = 2

    public private(set) var files: [File]
    /// Called after any file's state changes.
    var changed: () -> Void = {}
    private var work: Task<Void, Never>?

    init(files: [File]) {
        precondition(
            !files.isEmpty && files.count <= AnalysisRules.comparedFiles,
            "the window shows 1 to \(AnalysisRules.comparedFiles) files")
        self.files = files
    }

    /// Analyzes every file through `analyze`, `filesAtOnce` at a time, in order.
    func start(_ analyze: @escaping Analyze) {
        precondition(work == nil, "the window's files are analyzed once")
        let paths = files.map(\.path)
        // Held until the work ends, which closing the window makes it do.
        work = Task {
            await withTaskGroup(of: Void.self) { group in
                for index in paths.indices {
                    if index >= Self.filesAtOnce { await group.next() }
                    // Once the window closes, the files not started never start.
                    guard
                        group.addTaskUnlessCancelled(operation: {
                            await self.analyze(index, path: paths[index], analyze)
                        })
                    else { break }
                }
            }
        }
    }

    private nonisolated func analyze(_ index: Int, path: String, _ analyze: Analyze) async {
        await set(index, .analyzing(0))
        let state: State
        do {
            let result = try await analyze(path) { [weak self] share in
                Task { @MainActor in self?.progressed(index, share) }
            }
            state = .analyzed(result)
        } catch is CancellationError {
            return
        } catch {
            state = .failed("\(error)")
        }
        await set(index, state)
    }

    private func set(_ index: Int, _ state: State) {
        files[index].state = state
        changed()
    }

    /// A share read, unless the file finished or failed meanwhile.
    private func progressed(_ index: Int, _ share: Double) {
        guard case .analyzing = files[index].state else { return }
        set(index, .analyzing(share))
    }

    /// Stops the analyses still running, as the window closes.
    func cancel() {
        work?.cancel()
    }

    /// Returns once every file has finished, failed or been cancelled.
    func finished() async {
        await work?.value
    }

    var results: [AnalysisResult?] {
        files.map {
            if case .analyzed(let result) = $0.state { result } else { nil }
        }
    }

    /// The top of the shared frequency axis: the highest Nyquist frequency analyzed so far, or
    /// a CD's before any is.
    var topHz: Double {
        results.compactMap { $0?.spectrogram.nyquistHz }.max() ?? Self.cdNyquistHz
    }

    /// The reference lines under the top of the axis.
    var referenceLines: [Double] { Self.referenceHz.filter { $0 < topHz } }

    /// What the pointer is over in file `index`'s spectrogram, at `x` across its time and `y`
    /// up its height, each from 0 to 1: "1:23 · 16.2 kHz · -63 dB".
    func readout(file index: Int, x: Double, y: Double) -> String? {
        guard let spectrogram = results[index]?.spectrogram, (0...1).contains(x),
            (0...1).contains(y)
        else { return nil }
        let hertz = y * topHz
        let place = "\(clock(x * spectrogram.durationSeconds)) · \(kilohertzLabel(hertz))"
        guard hertz < spectrogram.nyquistHz else { return place + " · over this file's Nyquist" }
        let column = min(spectrogram.columns - 1, Int(x * Double(spectrogram.columns)))
        let row = min(
            Spectrogram.rows - 1, Int(hertz / spectrogram.nyquistHz * Double(Spectrogram.rows)))
        return place + " · " + decibelsText(spectrogram.level(column: column, row: row))
    }

    /// What the pointer is over in the average spectrum chart, `y` up its frequency axis: each
    /// analyzed file's level there.
    func averageReadout(y: Double) -> String? {
        guard (0...1).contains(y) else { return nil }
        let hertz = y * topHz
        let levels = zip(names, results).compactMap { name, result -> String? in
            guard let spectrogram = result?.spectrogram, hertz < spectrogram.nyquistHz else {
                return nil
            }
            let row = min(
                Spectrogram.rows - 1, Int(hertz / spectrogram.nyquistHz * Double(Spectrogram.rows)))
            let level = decibelsText(Double(spectrogram.averageDB[row]))
            return files.count == 1 ? level : "\(name) \(level)"
        }
        guard !levels.isEmpty else { return nil }
        return "\(kilohertzLabel(hertz)) · " + levels.joined(separator: " · ")
    }

    /// The legend's line for file `index`: its title and format.
    func legend(_ index: Int) -> String {
        guard let measures = results[index]?.measures else { return files[index].title }
        return "\(files[index].title) — \(formatLine(measures))"
    }

    /// File `index`'s header: its title and album, and its file type where that's what its
    /// name tells it apart by.
    func heading(_ index: Int) -> String {
        let file = files[index]
        let album = file.album.map { " — \($0)" } ?? ""
        let type = names[index] == Self.byType(file) ? " (\(file.fileType))" : ""
        return file.title + album + type
    }

    /// What the legend and the differences call each file: its title, or where titles repeat,
    /// its file type ("the FLAC"), or where that repeats too, its place ("file 2").
    var names: [String] {
        files.indices.map { index in
            let file = files[index]
            let sameTitle = files.filter { $0.title == file.title }
            if sameTitle.count == 1 { return file.title }
            if sameTitle.filter({ $0.fileType == file.fileType }).count == 1 {
                return Self.byType(file)
            }
            return "file \(index + 1)"
        }
    }

    private static func byType(_ file: File) -> String { "the \(file.fileType)" }

    /// The line under file `index`'s title: its progress, its format and size, or why it
    /// failed.
    func status(_ index: Int) -> String {
        switch files[index].state {
        case .waiting: "Waiting to start"
        case .analyzing(let share): "Analyzing… \(Int((share * 100).rounded()))%"
        case .analyzed(let result):
            formatLine(result.measures)
                + (files[index].sizeBytes.map { " · " + fileSizeText($0) } ?? "")
        case .failed(let reason): "Couldn't analyze: \(reason)"
        }
    }

    /// File `index`'s verdicts' lines, or that there's nothing to say, once analyzed.
    func verdictLines(_ index: Int) -> [String] {
        guard let measures = results[index]?.measures else { return [] }
        let lines = verdicts(measures).map(\.text)
        return lines.isEmpty ? [noVerdictText] : lines
    }

    /// File `index`'s measures, named, once analyzed.
    func measures(_ index: Int) -> [(name: String, value: String)] {
        results[index].map { measureItems($0.measures) } ?? []
    }
}

extension SpectrumModel.File {
    /// The file at `path`, named as the index has it, or by its file name where the index has
    /// no row.
    init(path: String, row: TrackRow?) {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        self.init(
            path: path, title: row?.title ?? url.deletingPathExtension().lastPathComponent,
            album: row?.album, sizeBytes: row?.sizeBytes,
            fileType: row?.fileType ?? url.pathExtension.uppercased())
    }
}

/// -63.4 -> "-63 dB", or "under -150 dB" at the floor of the scale.
func decibelsText(_ level: Double) -> String {
    level <= Spectrogram.floorDB
        ? "under \(Int(Spectrogram.floorDB)) dB" : String(format: "%.0f dB", level)
}
