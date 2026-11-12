import AppKit
import DisplayText
import Library
import Recommender
import Settings

/// The Marked sheet (phase 86, question 5): every mark, newest first, each named from this
/// Mac's catalog where it has the album, else `release 4242`, with Remove Mark on the
/// selected ones.
@MainActor
final class MarkedSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    enum Column: String {
        case name, verdict, set
    }

    /// The marks with their names, newest first.
    private(set) var marks: [(mark: FeedbackMark, name: String)]
    let table = NSTableView()
    let removeButton = NSButton(title: "Remove Mark", target: nil, action: nil)
    /// Hears Remove Mark on the selected marks.
    var removeChosen: ([FeedbackMark]) -> Void = { _ in }
    /// Hears Done.
    var done: () -> Void = {}

    init(_ marks: [(mark: FeedbackMark, name: String)]) {
        self.marks = marks.sorted { $0.mark.seq > $1.mark.seq }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 420, height: 240)
        super.init(window: window)
        build(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    private func build(in window: NSWindow) {
        let title = NSTextField(labelWithString: "Marked")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        for (column, heading, width) in [
            (Column.name, TrackColumn.album.title, 300.0), (.verdict, "Mark", 110.0),
            (.set, "Set", 120.0),
        ] {
            table.addColumn(
                NSUserInterfaceItemIdentifier(column.rawValue), title: heading, width: width,
                stretches: column == .name)
        }
        table.allowsMultipleSelection = true
        let scroll = table.inListScrollView(source: self)
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.isEnabled = false
        let doneButton = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        doneButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [removeButton, NSView(), doneButton])
        let page = NSStackView(views: [title, scroll, buttons])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for view in [scroll, buttons] {
            view.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -28).isActive = true
        }
        window.contentView = page
    }

    @objc private func removeClicked() {
        let chosen = table.selectedRowIndexes.filter { $0 < marks.count }
        guard !chosen.isEmpty else { return }
        removeChosen(chosen.map { marks[$0].mark })
        marks = marks.indices.filter { !chosen.contains($0) }.map { marks[$0] }
        table.reloadData()
    }

    @objc private func doneClicked() { done() }

    func numberOfRows(in tableView: NSTableView) -> Int { marks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let tableColumn, row < marks.count else { return nil }
        let (mark, name) = marks[row]
        let text =
            switch Column(rawValue: tableColumn.identifier.rawValue) {
            case .name: name
            case .verdict: verdictTitle(mark.verdict)
            case .set:
                DateFormatter.localizedString(
                    from: Date(timeIntervalSince1970: TimeInterval(mark.at)), dateStyle: .medium,
                    timeStyle: .short)
            case nil: ""
            }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }
}

/// The button and menu item that set `verdict`, and the Marked sheet's name for it.
func verdictTitle(_ verdict: FeedbackMark.Verdict) -> String {
    switch verdict {
    case .notInterested: "Not Interested"
    case .alreadyHave: "Already Have"
    }
}
