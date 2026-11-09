import AppKit
import Commands
import Settings

/// A strip across the top of the main window while the config file has a problem or the app's
/// files can't be saved: the first problem, how many more, all of them in the tooltip, and Open
/// Config File, with Remove Obsolete Setting while the file has keys the app doesn't know. An
/// alert would interrupt on every save of a half-edited line; the banner just stays until the
/// file is good. Problems that leave the rest of the file applying can be closed, and stay
/// hidden until the file is edited; one that blocks the file can't.
@MainActor
public final class ConfigBanner: NSViewController {
    static let removeTitle = "Remove Obsolete Setting"
    /// What a config file with a problem that refuses every change means.
    static let blockedText = "Nothing in it applies, and nothing can change, until it's fixed."
    /// The line a pane or the bar builder shows while the file refuses every change.
    static let blockedLine = "The config file has a problem. \(blockedText)"
    static let removeAllTitle = "Remove Obsolete Settings"

    public var openConfigFile: () -> Void = {}
    /// Takes the unknown keys out of the config file.
    public var removeObsoleteSettings: () -> Void = {}
    private let label = NSTextField(wrappingLabelWithString: "")
    private lazy var removeButton = NSButton(
        title: Self.removeTitle, target: self, action: #selector(remove))
    private lazy var closeButton = NSButton(
        image: NSImage(
            systemSymbolName: "xmark", accessibilityDescription: "Hide these warnings")
            ?? NSImage(),
        target: self, action: #selector(dismissWarnings))

    /// What the last `show` was given, which the banner shows less what was dismissed.
    private struct Shown {
        var problems: [ConfigProblem]
        var writeFailure: String?
        var path: String
        var unwatched: String?
        var stateFailure: String?
        var stateDiscarded: String?
        var configEdits: Int
    }

    private var shown: Shown?
    /// The problems closed, and the edit of the file they were closed at.
    private var dismissed: (configEdits: Int, problems: [ConfigProblem])?

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
        closeButton.isBordered = false
        closeButton.controlSize = .small
        closeButton.toolTip = "Hide these warnings until the config file changes"
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, label, removeButton, button, closeButton])
        row.detachesHiddenViews = true
        row.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.15).cgColor
        view = row
        view.isHidden = true
    }

    /// Shows what's wrong, or hides the banner when nothing is. `unwatched` says why the library
    /// isn't watched. `stateFailure` is why the window layout couldn't be saved to the state file.
    /// `configEdits` counts the edits to the config file, as `ConfigStore.edits` does.
    public func show(
        problems: [ConfigProblem], writeFailure: String?, path: String, unwatched: String? = nil,
        stateFailure: String?, stateDiscarded: String?, configEdits: Int
    ) {
        shown = Shown(
            problems: problems, writeFailure: writeFailure, path: path, unwatched: unwatched,
            stateFailure: stateFailure, stateDiscarded: stateDiscarded, configEdits: configEdits)
        if let dismissed, dismissed.configEdits != configEdits { self.dismissed = nil }
        render()
    }

    private func render() {
        _ = view
        guard let shown else { return }
        // By what it says, not its line, which a patch above it or a removal moves.
        let problems = shown.problems.filter { problem in
            dismissed?.problems.contains {
                $0.message == problem.message && $0.obsoleteKey == problem.obsoleteKey
            } != true
        }
        let (writeFailure, unwatched) = (shown.writeFailure, shown.unwatched)
        let (stateFailure, stateDiscarded) = (shown.stateFailure, shown.stateDiscarded)
        let name = (shown.path as NSString).lastPathComponent
        let lines =
            (problems.map(\.description) + (writeFailure.map { ["couldn't save: \($0)"] } ?? [])
            + (unwatched.map { [$0] } ?? []))
            .map { "\(name): \($0)" }
            + (stateFailure.map { ["couldn't save the window layout: \($0)"] } ?? [])
            + (stateDiscarded.map { ["the saved window layout was reset: \($0)"] } ?? [])
        view.isHidden = lines.isEmpty
        let obsolete = problems.filter { $0.obsoleteKey != nil }.count
        removeButton.isHidden = obsolete == 0
        removeButton.title = obsolete > 1 ? Self.removeAllTitle : Self.removeTitle
        closeButton.isHidden = problems.isEmpty || problems.contains(where: \.blocks)
        guard let first = lines.first else { return }
        let more = lines.count > 1 ? " (\(lines.count - 1) more)" : ""
        let waiting =
            if problems.isEmpty {
                ""
            } else if problems.contains(where: \.blocks) {
                " " + Self.blockedText
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

    /// Whether the close button shows, for tests.
    var canDismiss: Bool { !closeButton.isHidden }

    /// Hides the problems shown, none of which blocks the file, until its contents change.
    @objc func dismissWarnings() {
        guard let shown, canDismiss else { return }
        dismissed = (shown.configEdits, shown.problems)
        render()
    }

    @objc private func open() { openConfigFile() }
    @objc private func remove() { removeObsoleteSettings() }
}
