import AppKit
import Discogs
import DisplayText

/// View Changes (51.12, after YATE's import screen): per file and tag, what it holds now and
/// what the mapping writes, each with a checkbox. Done keeps the boxes for Apply to All; Apply
/// writes this album after the confirmation.
@MainActor
final class ChangesSheet: NSWindowController, TaggerSheet, NSTableViewDataSource,
    NSTableViewDelegate
{
    /// A row: one change, or a file nothing can be written to.
    enum Row: Equatable {
        case change(file: String, TagChange)
        case unwritable(file: String, why: String)
    }

    let rows: [Row]
    private(set) var excluded: Set<TagChange.ID>
    let table = NSTableView()
    let summary = NSTextField(labelWithString: "")
    /// What the user answered: the boxes left unticked, and whether to apply now; nil for
    /// Cancel.
    private(set) var result: (excluded: Set<TagChange.ID>, apply: Bool)?

    init(set: AlbumChangeSet, excluded: Set<TagChange.ID>, title: String) {
        rows = set.files.flatMap { file -> [Row] in
            let name = (file.path as NSString).lastPathComponent
            if let why = file.unwritable { return [.unwritable(file: name, why: why)] }
            return file.changes.map { .change(file: name, $0) }
        }
        self.excluded = excluded
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 600, height: 300)
        super.init(window: window)
        build(in: window, title: title)
        showSummary()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    private func build(in window: NSWindow, title: String) {
        let heading = NSTextField(labelWithString: "Changes to \(title)")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.lineBreakMode = .byTruncatingTail
        summary.textColor = .secondaryLabelColor
        let scroll = taggerTable(
            table,
            [
                (.include, 24), (.fileName, 180), (.field, 130), (.tag, 150), (.current, 170),
                (.written, 170),
            ],
            source: self)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        let apply = NSButton(title: "Apply…", target: self, action: #selector(applyNow))
        apply.keyEquivalent = "\r"
        let buttons = NSStackView(views: [summary, NSView(), cancel, done, apply])
        let page = NSStackView(views: [heading, scroll, buttons])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for view in [scroll, buttons] {
            view.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -32).isActive = true
        }
        window.contentView = page
    }

    /// "12 of 14 changes in 3 files".
    private func showSummary() {
        let changes = rows.compactMap { row -> TagChange? in
            if case .change(_, let change) = row { change } else { nil }
        }
        let kept = changes.filter { !excluded.contains($0.id) }
        let files = Set(kept.map(\.id.fileID)).count
        summary.stringValue =
            "\(number(kept.count)) of \(count(changes.count, "change")) in "
            + count(files, "file")
    }

    /// Ticks or unticks the change on `row`.
    func toggle(_ row: Int) {
        guard case .change(_, let change) = rows[row] else { return }
        if excluded.remove(change.id) == nil { excluded.insert(change.id) }
        showSummary()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let id = tableColumn.flatMap({ TaggerColumn(rawValue: $0.identifier.rawValue) })
        else { return nil }
        switch rows[row] {
        case .unwritable(let file, let why):
            return NSTextField(labelWithString: id == .fileName ? file : id == .field ? why : "")
        case .change(let file, let change):
            if id == .include {
                let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(ticked))
                box.tag = row
                box.state = excluded.contains(change.id) ? .off : .on
                return box
            }
            let text =
                switch id {
                case .fileName: file
                case .field: change.field.title
                case .tag: change.tag.name
                case .current: change.current ?? ""
                default: change.new ?? "(removed)"
                }
            let cell = NSTextField(labelWithString: text)
            cell.lineBreakMode = .byTruncatingTail
            cell.toolTip = text
            if id == .current { cell.textColor = .secondaryLabelColor }
            return cell
        }
    }

    @objc private func ticked(_ sender: NSButton) { toggle(sender.tag) }

    @objc private func cancel() { endSheet() }

    @objc private func done() {
        result = (excluded, false)
        endSheet()
    }

    @objc private func applyNow() {
        result = (excluded, true)
        endSheet()
    }
}
