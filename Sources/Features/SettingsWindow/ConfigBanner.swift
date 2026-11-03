import AppKit
import Commands
import Settings

/// A strip across the top of the main window while the config file has a problem or the app's
/// files can't be saved: the first problem, how many more, all of them in the tooltip, and Open
/// Config File, with Remove Obsolete Setting while the file has keys the app doesn't know. An
/// alert would interrupt on every save of a half-edited line; the banner just stays until the
/// file is good.
@MainActor
public final class ConfigBanner: NSViewController {
    static let removeTitle = "Remove Obsolete Setting"
    static let removeAllTitle = "Remove Obsolete Settings"

    public var openConfigFile: () -> Void = {}
    /// Takes the unknown keys out of the config file.
    public var removeObsoleteSettings: () -> Void = {}
    private let label = NSTextField(wrappingLabelWithString: "")
    private lazy var removeButton = NSButton(
        title: Self.removeTitle, target: self, action: #selector(remove))

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
        let button = NSButton(
            title: AppCommands.title(of: .openConfigFile), target: self, action: #selector(open))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small
        removeButton.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, label, removeButton, button])
        row.detachesHiddenViews = true
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
        let obsolete = problems.filter { $0.obsoleteKey != nil }.count
        removeButton.isHidden = obsolete == 0
        removeButton.title = obsolete > 1 ? Self.removeAllTitle : Self.removeTitle
        guard let first = lines.first else { return }
        let more = lines.count > 1 ? " (\(lines.count - 1) more)" : ""
        let waiting =
            if problems.isEmpty {
                ""
            } else if problems.contains(where: \.blocks) {
                " Nothing in it applies, and changes wait, until it's fixed."
            } else {
                " The rest of it applies."
            }
        label.stringValue = "\(first)\(more).\(waiting)"
        label.toolTip = lines.joined(separator: "\n")
    }

    /// The banner's text, for tests.
    var text: String { label.stringValue }
    /// The remove button's title, nil while it's hidden, for tests.
    var removeButtonTitle: String? { removeButton.isHidden ? nil : removeButton.title }

    @objc private func open() { openConfigFile() }
    @objc private func remove() { removeObsoleteSettings() }
}
