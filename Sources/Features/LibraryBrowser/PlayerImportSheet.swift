import AppKit
import DisplayText
import Library

/// The import preview: an `NSAlert` sheet (ADR 0012) with a table of what changes, a path prefix
/// to replace, and the details, which fits a 1440x900 screen. Nothing is written until Import.
@MainActor
final class PlayerImportSheet: NSObject {
    /// Called with the plan shown when the user clicks Import, and with Swinsian's columns when
    /// Import column layout is on; the sheet has closed.
    var confirmed: (ImportPlan, SwinsianColumns?) -> Void = { _, _ in }
    /// Called when the sheet closes either way.
    var closed: () -> Void = {}

    let alert = NSAlert()
    private let session: PlayerImportSession
    /// Swinsian's track table, or why it couldn't be read; nil for a player without one.
    private let columns: Result<SwinsianColumns, any Error>?
    let columnsBox = NSButton(checkboxWithTitle: "Import column layout", target: nil, action: nil)
    private let headingLabel = NSTextField(wrappingLabelWithString: "")
    /// What changes on the left, how many on the right, a row for each field that changes.
    let changes = NSGridView(numberOfColumns: 2, rows: 0)
    let unchangedLabel = NSTextField(wrappingLabelWithString: "")
    let notesLabel = NSTextField(wrappingLabelWithString: "")
    let fromField = NSTextField()
    let toField = NSTextField()
    private let updateButton = NSButton(title: "Update Preview", target: nil, action: nil)
    let details = NSTextView()
    private let stack = NSStackView()
    /// Holds `stack`, inset to where the alert's title and text start.
    private let accessory = NSView()
    private var accessoryInset: NSLayoutConstraint?

    /// Wide enough for a NAS path in the details without wrapping most of them.
    static let width = 640.0
    static let detailsHeight = 240.0

    init(
        session: PlayerImportSession, player: PlayerLibrary.Player,
        columns: Result<SwinsianColumns, any Error>?
    ) {
        self.session = session
        self.columns = columns
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
            if response == .alertFirstButtonReturn, let plan = session.shown {
                confirmed(plan, columnsChosen)
            }
            closed()
        }
    }

    private func makeAccessory() {
        for label in [headingLabel, unchangedLabel, notesLabel] {
            label.preferredMaxLayoutWidth = Self.width
        }
        headingLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        unchangedLabel.textColor = .secondaryLabelColor
        changes.rowSpacing = 4
        changes.columnSpacing = 16
        // As wide as its rows, so each count stays near what it counts.
        changes.setContentHuggingPriority(.required, for: .horizontal)
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
        var views = [
            headingLabel, changes, unchangedLabel, notesLabel,
            NSTextField(labelWithString: "Replace the path prefix:"), fields, scroll,
        ]
        if let columns { views.append(columnsRow(columns)) }
        for view in views { stack.addArrangedSubview(view) }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(stack)
        let inset = stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor)
        accessoryInset = inset
        NSLayoutConstraint.activate([
            inset, stack.topAnchor.constraint(equalTo: accessory.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            fields.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: Self.detailsHeight),
            // The fields share what the label and button leave.
            fromField.widthAnchor.constraint(equalTo: toField.widthAnchor),
        ])
        alert.accessoryView = accessory
    }

    /// Swinsian's columns when they were read.
    private var readColumns: SwinsianColumns? {
        if case .success(let columns) = columns { columns } else { nil }
    }

    /// The columns to apply: read, and Import column layout on.
    private var columnsChosen: SwinsianColumns? {
        columnsBox.state == .on ? readColumns : nil
    }

    /// Import column layout, off at first, with what it would bring across, or why it can't.
    private func columnsRow(_ columns: Result<SwinsianColumns, any Error>) -> NSView {
        columnsBox.target = self
        columnsBox.action = #selector(columnsToggled)
        let note: String
        switch columns {
        case .success(let columns): note = columns.previewLine
        case .failure(let error):
            columnsBox.isEnabled = false
            note = terminalSafe("Swinsian's preferences: \(error)")
        }
        let label = NSTextField(labelWithString: note)
        label.textColor = .secondaryLabelColor
        return NSStackView(views: [columnsBox, label])
    }

    @objc private func columnsToggled() { show(session.shown) }

    /// Shows `plan`'s table and details, or none, and sizes the sheet to them, so the wrapped
    /// lines can't be cut off.
    private func show(_ plan: ImportPlan?) {
        let preview = plan?.preview
        if let plan, let preview {
            headingLabel.stringValue = preview.heading
            let lines = plan.detailLines + (columnsChosen?.detailLines ?? [])
            details.string = lines.isEmpty ? "Every track matched." : lines.joined(separator: "\n")
        }
        showChanges(preview?.rows ?? [])
        unchangedLabel.stringValue = preview?.unchanged ?? ""
        unchangedLabel.isHidden = preview?.unchanged == nil
        notesLabel.stringValue = preview?.notes.joined(separator: " · ") ?? ""
        notesLabel.isHidden = preview?.notes.isEmpty ?? true
        alert.buttons.first?.isEnabled =
            plan.map { $0.changesSomething || columnsChosen != nil } ?? false
        // The alert starts its title where it likes, apart from its accessory view, and moves
        // the accessory when its width changes, so the inset is measured again until it holds.
        sizeAccessory(inset: 0)
        for _ in 0..<3 {
            let gap = alertTitleGap()
            if abs(gap) < 0.5 { break }
            sizeAccessory(inset: (accessoryInset?.constant ?? 0) + gap)
        }
    }

    /// Sizes the accessory to its stack with `inset` of room on each side, and the alert to it.
    private func sizeAccessory(inset: CGFloat) {
        accessoryInset?.constant = inset
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        accessory.setFrameSize(NSSize(width: size.width + 2 * inset, height: size.height))
        // The window takes the accessory's size at the second layout.
        alert.layout()
        alert.layout()
    }

    /// How far right of the stack the alert's title starts.
    private func alertTitleGap() -> CGFloat {
        guard let title = alert.window.contentView?.textField(showing: alert.messageText) else {
            assertionFailure("The alert's title isn't in its window")
            return 0
        }
        return title.windowAlignmentMinX - stack.windowAlignmentMinX
    }

    /// Fills the table with `rows`, hidden when there are none.
    private func showChanges(_ rows: [ImportPreview.Row]) {
        while changes.numberOfRows > 0 {
            let row = changes.row(at: 0)
            let views = (0..<row.numberOfCells).compactMap { row.cell(at: $0).contentView }
            changes.removeRow(at: 0)
            for view in views { view.removeFromSuperview() }
        }
        for row in rows {
            changes.addRow(with: [
                NSTextField(labelWithString: row.change), NSTextField(labelWithString: row.count),
            ])
        }
        changes.isHidden = rows.isEmpty
    }

    @objc private func updatePreview() {
        let prefix = PathPrefix(from: fromField.stringValue, to: toField.stringValue)
        alert.buttons.first?.isEnabled = false
        Task {
            do {
                guard let plan = try await session.preview(prefix) else { return }
                show(plan)
            } catch {
                headingLabel.stringValue = "Couldn't preview that prefix: \(error)"
                details.string = ""
                show(nil)
            }
        }
    }
}

extension NSView {
    /// Where the view's content starts, which a label's text does a little inside its frame.
    fileprivate var windowAlignmentMinX: CGFloat {
        superview?.convert(alignmentRect(forFrame: frame), to: nil).minX ?? frame.minX
    }

    /// The first text field at or under the view that shows `text`.
    fileprivate func textField(showing text: String) -> NSTextField? {
        if let field = self as? NSTextField, field.stringValue == text { return field }
        for view in subviews { if let found = view.textField(showing: text) { return found } }
        return nil
    }
}
