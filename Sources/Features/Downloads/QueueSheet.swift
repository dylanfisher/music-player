import AppKit
import DisplayText
import Recommender

/// The Upgrades and From Library Selection sheets (54.13): albums with a box each, those that
/// can't be queued saying why, and the format to ask for. Ends with `result` set on Queue.
@MainActor
final class QueueSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    enum Column: String {
        case tick, title, detail
    }

    let choices: [QueueChoice]
    let policies: [FormatPolicy]
    let table = NSTableView()
    let policyPopUp: NSPopUpButton
    /// The button that queues, here and in Paste a Discogs Release.
    static let queueTitle = "Queue"
    let queueButton = NSButton(title: QueueSheet.queueTitle, target: nil, action: nil)
    let summary = NSTextField(labelWithString: "")
    /// The rows ticked.
    private(set) var ticked: Set<Int>
    /// The albums to queue, and the policy; nil for Cancel.
    private(set) var result: (choices: [QueueChoice], policy: FormatPolicy)?

    init(
        heading: String, note: String, choices: [QueueChoice], policies: [FormatPolicy],
        tickingAll: Bool
    ) {
        self.choices = choices
        self.policies = policies
        ticked = tickingAll ? Set(choices.indices.filter { choices[$0].refusal == nil }) : []
        policyPopUp = formatPopUp(policies)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 480, height: 260)
        super.init(window: window)
        build(in: window, heading: heading, note: note)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    private func build(in window: NSWindow, heading: String, note: String) {
        let title = NSTextField(labelWithString: heading)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let noteLabel = NSTextField(wrappingLabelWithString: note)
        noteLabel.textColor = .secondaryLabelColor
        for (column, width) in [(Column.tick, 24.0), (.title, 300.0), (.detail, 260.0)] {
            table.addColumn(
                NSUserInterfaceItemIdentifier(column.rawValue),
                title: column == .title ? DownloadColumn.album.title : "", width: width,
                stretches: column == .title)
        }
        let scroll = table.inListScrollView(source: self)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        queueButton.target = self
        queueButton.action = #selector(queue)
        queueButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [
            NSTextField(labelWithString: "Format:"), policyPopUp, summary, NSView(), cancel,
            queueButton,
        ])
        let page = NSStackView(views: [title, noteLabel, scroll, buttons])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for view in [noteLabel, scroll, buttons] {
            view.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -32).isActive = true
        }
        window.contentView = page
    }

    private func refresh() {
        summary.stringValue = "\(ticked.count) of \(choices.count) to queue"
        queueButton.isEnabled = !ticked.isEmpty
    }

    /// Ticks or unticks `row`; a row that can't be queued has no box.
    func toggle(_ row: Int) {
        guard row < choices.count, choices[row].refusal == nil else { return }
        if ticked.remove(row) == nil { ticked.insert(row) }
        table.reloadData(
            forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        refresh()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { choices.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let choice = choices[row]
        switch tableColumn.flatMap({ Column(rawValue: $0.identifier.rawValue) }) {
        case .tick:
            guard choice.refusal == nil else { return nil }
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(boxClicked))
            box.tag = row
            box.state = ticked.contains(row) ? .on : .off
            return box
        case .title:
            let label = NSTextField(labelWithString: choice.title)
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = choice.title
            if choice.refusal != nil { label.textColor = .secondaryLabelColor }
            return label
        case .detail, nil:
            let label = NSTextField(labelWithString: choice.refusal ?? choice.detail)
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = label.stringValue
            label.textColor = .secondaryLabelColor
            return label
        }
    }

    @objc private func boxClicked(_ sender: NSButton) { toggle(sender.tag) }

    @objc private func cancel() { endSheet() }

    @objc private func queue() {
        guard !ticked.isEmpty else { return }
        result = (ticked.sorted().map { choices[$0] }, policies[policyPopUp.indexOfSelectedItem])
        endSheet()
    }
}

/// A pop-up of `policies`, the first chosen.
@MainActor
func formatPopUp(_ policies: [FormatPolicy]) -> NSPopUpButton {
    let popUp = NSPopUpButton()
    popUp.addItems(withTitles: policies.map(DownloadRow.policyName))
    popUp.selectItem(at: 0)
    return popUp
}

extension NSWindowController {
    /// Ends the sheet this controller's window is.
    func endSheet() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
