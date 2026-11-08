import AppKit
import Discogs
import DisplayText
import Settings

/// View Changes (51.12, after YATE's import screen): per tag, what the files hold now and what
/// the mapping writes, each with a checkbox. A change the same in several files is one row, so
/// a release's URLs and credits show once, not once per track. Done keeps the boxes for Apply
/// to All; Apply writes this album after the confirmation.
@MainActor
final class ChangesSheet: NSWindowController, TaggerSheet, NSTableViewDataSource,
    NSTableViewDelegate
{
    /// A row: one change in each of `files`, the same tag from the same value to the same
    /// value, or a file nothing can be written to.
    enum Row: Equatable {
        case change(files: [String], [TagChange])
        case unwritable(file: String, why: String)
    }

    let rows: [Row]
    /// How many files the set can write to, for "All 18 files".
    private let writable: Int
    private(set) var excluded: Set<TagChange.ID>
    let table = NSTableView()
    let summary = NSTextField(labelWithString: "")
    /// What the user answered: the boxes left unticked, and whether to apply now; nil for
    /// Cancel.
    private(set) var result: (excluded: Set<TagChange.ID>, apply: Bool)?
    /// The release the changes come from.
    let releaseID: Int

    /// The release's page on Discogs.
    var discogsURL: URL { discogsPage(releaseID) }

    init(set: AlbumChangeSet, excluded: Set<TagChange.ID>, title: String, releaseID: Int) {
        self.releaseID = releaseID
        rows = Self.rows(set)
        writable = set.files.filter { $0.unwritable == nil }.count
        self.excluded = excluded
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 600, height: 300)
        super.init(window: window)
        build(in: window, title: title)
        showSummary()
    }

    /// The changes merged by tag, current value and new value, in the order of the mapping's
    /// tags and then of the files; then the files nothing can be written to.
    private static func rows(_ set: AlbumChangeSet) -> [Row] {
        struct Key: Hashable {
            var tag: MappedTag
            var current: String?
            var new: String?
        }
        var tagOrder: [MappedTag: Int] = [:]
        var keys: [Key] = []
        var groups: [Key: (files: [String], changes: [TagChange])] = [:]
        var unwritable: [Row] = []
        for file in set.files {
            let name = (file.path as NSString).lastPathComponent
            if let why = file.unwritable {
                unwritable.append(.unwritable(file: name, why: why))
                continue
            }
            for change in file.changes {
                let key = Key(tag: change.tag, current: change.current, new: change.new)
                if tagOrder[change.tag] == nil { tagOrder[change.tag] = tagOrder.count }
                if groups[key] == nil { keys.append(key) }
                groups[key, default: ([], [])].files.append(name)
                groups[key, default: ([], [])].changes.append(change)
            }
        }
        let ordered = keys.indices.sorted { (a: Int, b: Int) -> Bool in
            let (tagA, tagB) = (tagOrder[keys[a].tag]!, tagOrder[keys[b].tag]!)
            return tagA != tagB ? tagA < tagB : a < b
        }
        return ordered.map { index -> Row in
            let group = groups[keys[index]]!
            return .change(files: group.files, group.changes)
        } + unwritable
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
        let open = NSButton(title: openOnDiscogsTitle, target: self, action: #selector(open))
        let buttons = NSStackView(views: [summary, NSView(), open, cancel, done, apply])
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
        let changes = rows.flatMap { row -> [TagChange] in
            if case .change(_, let changes) = row { changes } else { [] }
        }
        let kept = changes.filter { !excluded.contains($0.id) }
        let files = Set(kept.map(\.id.fileID)).count
        summary.stringValue =
            "\(number(kept.count)) of \(count(changes.count, "change")) in "
            + count(files, "file")
    }

    /// Ticks or unticks the change on `row` in each of its files: unticks them all when any
    /// is ticked.
    func toggle(_ row: Int) {
        guard case .change(_, let changes) = rows[row] else { return }
        let ids = Set(changes.map(\.id))
        if ids.isSubset(of: excluded) {
            excluded.subtract(ids)
        } else {
            excluded.formUnion(ids)
        }
        showSummary()
    }

    /// The row's files as the File Name column shows them: the one file's name, "All 18 files"
    /// or "3 files".
    func filesText(_ files: [String]) -> String {
        if files.count == 1 { return files[0] }
        let text = count(files.count, "file")
        return files.count == writable ? "All \(text)" : text
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// The text of the cell in column `id` of `row`.
    func text(_ id: TaggerColumn, _ row: Int) -> String {
        switch rows[row] {
        case .unwritable(let file, let why):
            return id == .fileName ? file : id == .field ? why : ""
        case .change(let files, let changes):
            let change = changes[0]
            switch id {
            case .fileName: return filesText(files)
            case .field: return change.field.title
            case .tag: return change.tag.name
            case .current: return change.current ?? ""
            default: return change.new ?? "(removed)"
            }
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let id = tableColumn.flatMap({ TaggerColumn(rawValue: $0.identifier.rawValue) })
        else { return nil }
        switch rows[row] {
        case .unwritable:
            return NSTextField(labelWithString: text(id, row))
        case .change(let files, let changes):
            if id == .include {
                let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(ticked))
                box.tag = row
                let unticked = changes.filter { excluded.contains($0.id) }.count
                box.allowsMixedState = unticked != 0 && unticked != changes.count
                box.state = unticked == 0 ? .on : box.allowsMixedState ? .mixed : .off
                return box
            }
            let text = text(id, row)
            let cell = NSTextField(labelWithString: text)
            cell.lineBreakMode = .byTruncatingTail
            cell.toolTip = id == .fileName ? files.joined(separator: "\n") : text
            if id == .current { cell.textColor = .secondaryLabelColor }
            return cell
        }
    }

    /// Toggles the row, then redraws its box, which a click on a mixed box leaves wrong.
    @objc private func ticked(_ sender: NSButton) {
        toggle(sender.tag)
        table.reloadData(forRowIndexes: [sender.tag], columnIndexes: [0])
    }

    @objc private func open() { NSWorkspace.shared.open(discogsURL) }

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
