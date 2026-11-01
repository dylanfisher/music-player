import AppKit
import Library

/// The import preview: an `NSAlert` sheet (ADR 0012) with the counts, a path prefix to replace,
/// and the details, which fits a 1440x900 screen. Nothing is written until Import.
@MainActor
final class PlayerImportSheet: NSObject {
    /// Called with the plan shown when the user clicks Import; the sheet has closed.
    var confirmed: (ImportPlan) -> Void = { _ in }
    /// Called when the sheet closes either way.
    var closed: () -> Void = {}

    let alert = NSAlert()
    private let session: PlayerImportSession
    private let countsLabel = NSTextField(wrappingLabelWithString: "")
    let fromField = NSTextField()
    let toField = NSTextField()
    private let updateButton = NSButton(title: "Update Preview", target: nil, action: nil)
    private let details = NSTextView()
    private let stack = NSStackView()

    /// Wide enough for a NAS path in the details without wrapping most of them.
    static let width = 640.0
    static let detailsHeight = 240.0

    init(session: PlayerImportSession, player: PlayerLibrary.Player) {
        self.session = session
        super.init()
        alert.messageText = "Import from \(player.title)"
        alert.informativeText =
            "Nothing changes until you click Import. Music files aren't touched."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        makeAccessory()
        if let prefix = session.shown?.prefix {
            fromField.stringValue = prefix.from
            toField.stringValue = prefix.to
        }
        show(session.shown)
    }

    func begin(over window: NSWindow) {
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn, let plan = session.shown { confirmed(plan) }
            closed()
        }
    }

    private func makeAccessory() {
        countsLabel.preferredMaxLayoutWidth = Self.width
        fromField.placeholderString = "/Volumes/old"
        toField.placeholderString = "/Volumes/music"
        updateButton.target = self
        updateButton.action = #selector(updatePreview)
        let fields = NSStackView(views: [
            fromField, NSTextField(labelWithString: "with"), toField, updateButton,
        ])
        details.isEditable = false
        details.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        details.isVerticallyResizable = true
        details.autoresizingMask = [.width]
        details.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.detailsHeight)
        let scroll = NSScrollView()
        scroll.documentView = details
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        for view in [
            countsLabel, NSTextField(labelWithString: "Replace the path prefix:"), fields, scroll,
        ] {
            stack.addArrangedSubview(view)
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            fields.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: Self.detailsHeight),
            // The fields share what the label and button leave.
            fromField.widthAnchor.constraint(equalTo: toField.widthAnchor),
        ])
        alert.accessoryView = stack
    }

    /// Shows `plan`'s counts and details, or none, and sizes the sheet to them, so the wrapped
    /// counts can't be cut off.
    private func show(_ plan: ImportPlan?) {
        if let plan {
            countsLabel.stringValue = plan.previewLines.joined(separator: "\n")
            let lines = plan.detailLines
            details.string = lines.isEmpty ? "Every track matched." : lines.joined(separator: "\n")
        }
        alert.buttons.first?.isEnabled = plan?.changesSomething ?? false
        stack.layoutSubtreeIfNeeded()
        stack.setFrameSize(stack.fittingSize)
        alert.layout()
    }

    @objc private func updatePreview() {
        let prefix = PathPrefix(from: fromField.stringValue, to: toField.stringValue)
        alert.buttons.first?.isEnabled = false
        Task {
            do {
                guard let plan = try await session.preview(prefix) else { return }
                show(plan)
            } catch {
                countsLabel.stringValue = "Couldn't preview that prefix: \(error)"
                details.string = ""
                show(nil)
            }
        }
    }
}
