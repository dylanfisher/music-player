import Analysis
import AppKit

/// Show Spectrum's window (ADR 0115): each file's title, progress or format line, spectrogram
/// and verdicts, stacked on one frequency axis scaled to the highest Nyquist; beside them every
/// average spectrum on one chart with a legend, and the dB scale; for one file, its measures
/// too. The line at the bottom says what the pointer is over. Closing it cancels the analyses
/// still running.
@MainActor
final class SpectrumWindow: NSWindowController, NSWindowDelegate {
    static let title = "Spectrum"

    let model: SpectrumModel
    private let titles: [NSTextField]
    private let statuses: [NSTextField]
    private let progress: [NSProgressIndicator]
    private let spectrograms: [SpectrogramView]
    private let verdictLabels: [NSTextField]
    private let measuresLabel = NSTextField(wrappingLabelWithString: "")
    private let average = AverageSpectrumView()
    private let legends: [NSTextField]
    private let readout = NSTextField(labelWithString: " ")
    /// Called once the window has closed.
    var closed: () -> Void = {}

    init(model: SpectrumModel) {
        self.model = model
        let count = model.files.count
        titles = (0..<count).map { _ in NSTextField(labelWithString: "") }
        statuses = (0..<count).map { _ in NSTextField(labelWithString: "") }
        progress = (0..<count).map { _ in NSProgressIndicator() }
        spectrograms = (0..<count).map { _ in SpectrogramView() }
        verdictLabels = (0..<count).map { _ in NSTextField(wrappingLabelWithString: "") }
        legends = (0..<count).map { _ in NSTextField(labelWithString: "") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: count == 1 ? 640 : 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.title =
            count == 1 ? "\(Self.title): \(model.files[0].title)" : "\(Self.title): \(count) files"
        super.init(window: window)
        window.delegate = self
        build(in: window)
        model.changed = { [weak self] in self?.refresh() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    private func build(in window: NSWindow) {
        var rows: [NSView] = []
        for index in model.files.indices {
            titles[index].stringValue = model.files[index].title
            titles[index].font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            titles[index].lineBreakMode = .byTruncatingMiddle
            if model.files.count > 1 { titles[index].textColor = SpectrumColors.files[index] }
            statuses[index].textColor = .secondaryLabelColor
            statuses[index].lineBreakMode = .byTruncatingTail
            progress[index].style = .bar
            progress[index].isIndeterminate = false
            progress[index].minValue = 0
            progress[index].maxValue = 1
            progress[index].controlSize = .small
            verdictLabels[index].font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            spectrograms[index].pointerMoved = { [weak self] place in
                self?.show(place.flatMap { self?.model.readout(file: index, x: $0.x, y: $0.y) })
            }
            let header = NSStackView(views: [titles[index], statuses[index], progress[index]])
            header.spacing = 8
            header.setHuggingPriority(.defaultHigh, for: .vertical)
            titles[index].setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            statuses[index].setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            progress[index].widthAnchor.constraint(equalToConstant: 120).isActive = true
            let row = NSStackView(views: [header, spectrograms[index], verdictLabels[index]])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 3
            for view in [header, spectrograms[index], verdictLabels[index]] {
                view.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            }
            spectrograms[index].heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
                .isActive = true
            rows.append(row)
        }
        if model.files.count == 1 {
            measuresLabel.font = .monospacedDigitSystemFont(
                ofSize: NSFont.smallSystemFontSize, weight: .regular)
            rows.append(measuresLabel)
        }
        let left = NSStackView(views: rows)
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 12
        for row in rows { row.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true }
        // Once they share an ancestor: the stacked spectrograms share the height.
        for spectrogram in spectrograms.dropFirst() {
            spectrogram.heightAnchor.constraint(equalTo: spectrograms[0].heightAnchor).isActive =
                true
        }

        average.pointerMoved = { [weak self] place in
            self?.show(place.flatMap { self?.model.averageReadout(y: $0.y) })
        }
        let averageTitle = NSTextField(labelWithString: "Average spectrum")
        averageTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        for (index, legend) in legends.enumerated() {
            legend.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            legend.textColor = SpectrumColors.files[index]
            legend.lineBreakMode = .byTruncatingTail
        }
        let scale = DecibelScaleView()
        let right = NSStackView(views: [averageTitle, average] + legends + [scale])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 4
        for view in [average] + legends + [scale] as [NSView] {
            view.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        }
        average.setContentHuggingPriority(.defaultLow, for: .vertical)

        readout.textColor = .secondaryLabelColor
        readout.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let content = NSView()
        for view in [left, right, readout] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            left.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            left.bottomAnchor.constraint(equalTo: readout.topAnchor, constant: -10),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 18),
            right.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            right.topAnchor.constraint(equalTo: left.topAnchor),
            right.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            right.widthAnchor.constraint(equalTo: left.widthAnchor, multiplier: 0.36),
            readout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            readout.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
            readout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        window.contentView = content
    }

    private func show(_ text: String?) {
        readout.stringValue = text ?? " "
    }

    /// Shows each file's state and the charts as the model has them.
    func refresh() {
        let results = model.results
        for index in model.files.indices {
            statuses[index].stringValue = model.status(index)
            if case .analyzing(let share) = model.files[index].state {
                progress[index].isHidden = false
                progress[index].doubleValue = share
            } else {
                progress[index].isHidden = true
            }
            spectrograms[index].topHz = model.topHz
            spectrograms[index].referenceHz = model.referenceLines
            if spectrograms[index].spectrogram != results[index]?.spectrogram {
                spectrograms[index].spectrogram = results[index]?.spectrogram
            }
            spectrograms[index].setAccessibilityLabel(
                "Spectrogram of \(model.files[index].title)")
            verdictLabels[index].stringValue = model.verdictLines(index).joined(separator: "\n")
            legends[index].stringValue = model.legend(index)
        }
        average.topHz = model.topHz
        average.referenceHz = model.referenceLines
        average.spectrograms = results.map { $0?.spectrogram }
        average.setAccessibilityLabel("Average spectrum")
        if model.files.count == 1 {
            measuresLabel.stringValue = model.measures(0).map { "\($0.name): \($0.value)" }
                .joined(separator: "\n")
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.cancel()
        closed()
    }
}
