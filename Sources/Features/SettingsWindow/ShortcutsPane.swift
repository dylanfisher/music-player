import AppKit
import Commands
import DisplayText
import KeyChord
import Settings

/// Settings ▸ Shortcuts: a search field, the commands in sections as the menus list them, two
/// recorders and Reset per row, a notice under a row when a recording needs an answer, and Reset
/// All.
@MainActor
final class ShortcutsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate
{
    private enum Line {
        case section(String)
        case command(CommandID)
    }

    let model: ShortcutsModel
    private let search = NSSearchField()
    private let table = NSTableView()
    private let resetAll = NSButton()
    private var lines: [Line] = []

    init(model: ShortcutsModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override func loadView() {
        search.placeholderString = "Search by name or shortcut, such as ⇧⌘P"
        search.delegate = self
        let column = NSTableColumn(identifier: CommandRow.identifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .fullWidth
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        resetAll.title = "Reset All"
        resetAll.bezelStyle = .rounded
        resetAll.target = self
        resetAll.action = #selector(resetEverything)
        let footer = NSStackView(views: [resetAll])
        let stack = NSStackView(views: [search, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(
            top: DialogMargin.value, left: DialogMargin.value, bottom: DialogMargin.value,
            right: DialogMargin.value)
        for view in [search, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -2 * DialogMargin.value
            ).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: GeneralPane.width),
            scroll.heightAnchor.constraint(equalToConstant: 460),
        ])
        view = stack
        reload()
    }

    /// Lists the commands again, after the bindings or the search changed.
    func reload() {
        lines = model.filtered(search.stringValue).flatMap { section in
            [Line.section(section.title)] + section.commands.map(Line.command)
        }
        resetAll.isEnabled = model.hasOverrides
        table.reloadData()
    }

    func controlTextDidChange(_ notification: Notification) { reload() }

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .section = lines[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard case .command(let id) = lines[row] else { return 24 }
        return model.notices[id] != nil || !model.losses(id).isEmpty ? 54 : 30
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        switch lines[row] {
        case .section(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            return label
        case .command(let id):
            let view = CommandRow()
            view.show(id, model: model) { [weak self] in self?.reload() }
            return view
        }
    }

    @objc private func resetEverything() {
        model.resetAll()
        reload()
    }
}

/// One command's row: its title, a recorder for each slot, Reset, and a line under them for a
/// notice or what a clash cost it.
@MainActor
private final class CommandRow: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CommandRow")

    func show(_ id: CommandID, model: ShortcutsModel, changed: @escaping () -> Void) {
        let title = NSTextField(labelWithString: model.title(id))
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The title takes the row's spare width, so the recorders line up in columns.
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var recorders: [ShortcutRecorder] = []
        for position in ShortcutPosition.allCases {
            let recorder = ShortcutRecorder()
            recorder.setContentHuggingPriority(.required, for: .horizontal)
            recorder.chord = model.chord(id, position)
            recorder.isEnabled = !(position == .primary && model.bindings.rules.fixed[id] != nil)
            recorder.setAccessibilityLabel("\(model.title(id)), \(position.rawValue) shortcut")
            recorder.recorded = { chord in
                model.record(chord, for: id, at: position)
                changed()
            }
            recorder.removed = {
                model.remove(from: id, at: position)
                changed()
            }
            recorders.append(recorder)
        }
        let reset = Button("Reset") {
            model.reset(id)
            changed()
        }
        reset.isEnabled = model.hasOverride(id)
        let top = NSStackView(views: [title] + recorders + [reset])
        top.distribution = .fill
        var lines: [NSView] = [top]
        if let notice = model.notices[id] {
            let text = NSTextField(labelWithString: model.text(of: notice))
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.textColor = .systemOrange
            var views: [NSView] = [text]
            if case .taken = notice {
                views.append(
                    Button("Replace") {
                        model.replace(for: id)
                        changed()
                    })
                views.append(
                    Button("Cancel") {
                        model.cancel(for: id)
                        changed()
                    })
            }
            lines.append(NSStackView(views: views))
            NSAccessibility.post(
                element: text, notification: .announcementRequested,
                userInfo: [
                    .announcement: text.stringValue,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        } else if let loss = model.losses(id).first {
            let text = NSTextField(labelWithString: loss)
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.textColor = .secondaryLabelColor
            lines.append(text)
        }
        let stack = NSStackView(views: lines)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
}

/// A small push button that runs a closure.
@MainActor
private final class Button: NSButton {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        target = self
        action = #selector(clicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    @objc private func clicked() { run() }
}
