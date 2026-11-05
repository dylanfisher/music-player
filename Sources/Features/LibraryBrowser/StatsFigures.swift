import AppKit

/// Large figures side by side, each its value over its name, sharing the width evenly: the
/// totals of Listening Stats.
final class StatsFigures: NSView {
    struct Figure: Equatable {
        var value: String
        var name: String
        /// What the figure means, in its tooltip.
        var help: String?
    }

    private let stack = NSStackView()
    /// The value labels, in order, for tests and VoiceOver.
    private(set) var valueLabels: [NSTextField] = []
    var valueFontSize: CGFloat = 22

    var figures: [Figure] = [] {
        didSet { if figures != oldValue { rebuild() } }
    }

    init() {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .top
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    private func rebuild() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        valueLabels = []
        for figure in figures {
            let value = NSTextField(labelWithString: figure.value)
            value.font = .monospacedDigitSystemFont(ofSize: valueFontSize, weight: .semibold)
            value.lineBreakMode = .byTruncatingTail
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let name = NSTextField(labelWithString: figure.name)
            name.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            name.textColor = .secondaryLabelColor
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let column = NSStackView(views: [value, name])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 0
            column.toolTip = figure.help
            column.setAccessibilityElement(true)
            column.setAccessibilityRole(.staticText)
            column.setAccessibilityLabel("\(figure.name): \(figure.value)")
            stack.addArrangedSubview(column)
            valueLabels.append(value)
        }
    }
}
