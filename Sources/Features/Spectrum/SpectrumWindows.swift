import Analysis
import AppKit
import Library
import WindowPlacement

/// The open Spectrum windows: Show Spectrum opens one for the files it's given, each analyzed
/// through `analyze`, and the window's closing cancels what it hasn't finished.
@MainActor
public final class SpectrumWindows {
    private let analyze: SpectrumModel.Analyze
    private(set) var open: [SpectrumWindow] = []

    public init(analyze: @escaping SpectrumModel.Analyze) {
        self.analyze = analyze
    }

    /// Opens a window on `files`, 1 to `AnalysisRules.comparedFiles` of them, each with its row
    /// in the index if it has one, cascaded from the last one open.
    public func show(_ files: [(path: String, row: TrackRow?)]) {
        let model = SpectrumModel(
            files: files.map { SpectrumModel.File(path: $0.path, row: $0.row) })
        let controller = SpectrumWindow(model: model)
        controller.closed = { [weak self, weak controller] in
            self?.open.removeAll { $0 === controller }
        }
        guard let window = controller.window else { return }
        // The first keeps its frame (ADR 0158); the rest cascade from the last one open.
        window.keepsFrame(as: SpectrumWindow.title, cascadedFrom: open.last?.window)
        open.append(controller)
        controller.showWindow(nil)
        model.start(analyze)
    }
}
