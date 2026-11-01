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
    private let fromField = NSTextField()
    private let toField = NSTextField()
    private let updateButton = NSButton(title: "Update Preview", target: nil, action: nil)
    private let details = NSTextView()

    /// Wide enough for a NAS path in the details without wrapping most of them.
    static let width = 640.0
    static let detailsHeight = 240.0

    init(session: PlayerImportSession) {
        self.session = session
        super.init()
        alert.messageText = "Import from \(session.shown.library.player.title)"
        alert.informativeText =
            "Nothing changes until you click Import. Music files aren't touched."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = makeAccessory()
        if let prefix = session.shown.prefix {
            fromField.stringValue = prefix.from
            toField.stringValue = prefix.to
        }
        show(session.shown)
    }

    func begin(over window: NSWindow) {
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { confirmed(session.shown) }
            closed()
        }
    }

    private func makeAccessory() -> NSView {
        countsLabel.preferredMaxLayoutWidth = Self.width
        fromField.placeholderString = "/Volumes/old"
        toField.placeholderString = "/Volumes/music"
        updateButton.target = self
        updateButton.action = #selector(updatePreview)
        let prefixRow = NSStackView(views: [
            NSTextField(labelWithString: "Replace the path prefix"), fromField,
            NSTextField(labelWithString: "with"), toField, updateButton,
        ])
        details.isEditable = false
        details.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        details.isVerticallyResizable = true
        details.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = details
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let stack = NSStackView(views: [countsLabel, prefixRow, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.detailsHeight + 200)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: Self.width),
            scroll.heightAnchor.constraint(equalToConstant: Self.detailsHeight),
            fromField.widthAnchor.constraint(equalToConstant: 160),
            toField.widthAnchor.constraint(equalToConstant: 160),
        ])
        details.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.detailsHeight)
        return stack
    }

    private func show(_ plan: ImportPlan) {
        countsLabel.stringValue = plan.previewLines.joined(separator: "\n")
        let lines = plan.detailLines
        details.string = lines.isEmpty ? "Every track matched." : lines.joined(separator: "\n")
        alert.buttons.first?.isEnabled = plan.changesSomething
    }

    @objc private func updatePreview() {
        let prefix = PathPrefix(from: fromField.stringValue, to: toField.stringValue)
        alert.buttons.first?.isEnabled = false
        Task {
            do {
                if let plan = try await session.preview(prefix) { show(plan) }
            } catch {
                countsLabel.stringValue = "Couldn't preview that prefix: \(error)"
                return
            }
            if !session.isPreviewing {
                alert.buttons.first?.isEnabled = session.shown.changesSomething
            }
        }
    }
}
