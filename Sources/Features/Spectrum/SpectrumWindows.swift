import Analysis
import AppKit

/// The open Spectrum windows: Show Spectrum opens one for the files it's given, each analyzed
/// through `analyze`, and the window's closing cancels what it hasn't finished.
@MainActor
public final class SpectrumWindows {
    private let analyze: SpectrumModel.Analyze
    private(set) var open: [SpectrumWindow] = []

    public init(analyze: @escaping SpectrumModel.Analyze) {
        self.analyze = analyze
    }

    /// Opens a window on `files`, 1 to `AnalysisRules.comparedFiles` of them, cascaded from the
    /// last one open.
    public func show(_ files: [(path: String, title: String)]) {
        let model = SpectrumModel(files: files)
        let controller = SpectrumWindow(model: model)
        controller.closed = { [weak self, weak controller] in
            self?.open.removeAll { $0 === controller }
        }
        guard let window = controller.window else { return }
        if let last = open.last?.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: last.frame.topLeft))
        } else {
            window.center()
        }
        open.append(controller)
        controller.showWindow(nil)
        model.start(analyze)
    }
}

extension NSRect {
    fileprivate var topLeft: NSPoint { NSPoint(x: minX, y: maxY) }
}
