import AppKit
import Settings

/// A strip across the top of the main window while the config file has a problem or the app's
/// files can't be saved: the first problem, how many more, all of them in the tooltip, and Open
/// Config File. An alert would interrupt on every save of a half-edited line; the banner just
/// stays until the file is good.
@MainActor
public final class ConfigBanner: NSViewController {
    public var openConfigFile: () -> Void = {}
    private let label = NSTextField(wrappingLabelWithString: "")

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override public func loadView() {
        let icon = NSImageView(
            image: NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "Config file problem") ?? NSImage())
        icon.contentTintColor = .systemOrange
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.maximumNumberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let button = NSButton(title: "Open Config File", target: self, action: #selector(open))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, label, button])
        row.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.15).cgColor
        view = row
        view.isHidden = true
    }

    /// Shows what's wrong, or hides the banner when nothing is. `stateFailure` is why the window
    /// layout couldn't be saved to the state file.
    public func show(
        problems: [ConfigProblem], writeFailure: String?, path: String, stateFailure: String?,
        stateDiscarded: String?
    ) {
        _ = view
        let name = (path as NSString).lastPathComponent
        let lines =
            (problems.map(\.description) + (writeFailure.map { ["couldn't save: \($0)"] } ?? []))
            .map { "\(name): \($0)" }
            + (stateFailure.map { ["couldn't save the window layout: \($0)"] } ?? [])
            + (stateDiscarded.map { ["the saved window layout was reset: \($0)"] } ?? [])
        view.isHidden = lines.isEmpty
        guard let first = lines.first else { return }
        let more = lines.count > 1 ? " (\(lines.count - 1) more)" : ""
        let waiting =
            problems.isEmpty ? "" : " Nothing in it applies, and changes wait, until it's fixed."
        label.stringValue = "\(first)\(more).\(waiting)"
        label.toolTip = lines.joined(separator: "\n")
    }

    /// The banner's text, for tests.
    var text: String { label.stringValue }

    @objc private func open() { openConfigFile() }
}
