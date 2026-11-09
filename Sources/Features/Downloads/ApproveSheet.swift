import Analysis
import AppKit
import DisplayText
import Library
import Settings

/// Approve… (54.13, ADR 0147), laid out as the tagger's sheets are: a heading and a line under
/// it, a table of the staged files with where each goes and what the lossy-origin check found,
/// and for an upgrade a table of the old files it deletes, with a box for each that has no new
/// file, to lose it. What still blocks Approve is one line beside the buttons. Approve ends the
/// sheet with `result` set.
@MainActor
final class ApproveSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    /// Said plainly, since the owner's library share has no Trash.
    static let deleteWarning =
        "These old files are deleted. On a share with no Trash, such as the NAS, they're deleted"
        + " permanently."
    /// For a job queued as a new album whose release is in the library already.
    static let replacesAlbumNote =
        "This release is already in the library, at the paths these files take. Approve replaces"
        + " that album, as an upgrade does, and keeps its tracks' plays, ratings, loves and"
        + " playlist entries."
    static let resumeNote =
        "The import stopped partway. It goes on from where the library and the import's record"
        + " say it got to."

    /// A staged file: its name, where it goes, and what the check found of it.
    struct FileRow: Equatable {
        var name: String
        /// Relative to the library folder; empty when the moves couldn't be worked out.
        var destination: String
        var check: String
        /// The check found something, or couldn't read the file.
        var warns: Bool
    }

    /// An upgrade's old file: where it is, its track, and what Approve does to it.
    struct OldRow: Equatable {
        var sharePath: String
        var path: String
        var position: String
        var note: String
        /// It has no new file, so it's deleted only once ticked.
        var tickable: Bool
    }

    enum Column: String {
        case tick, name, destination, check, old, position, note
    }

    let plan: ApprovalPlan
    let files: [FileRow]
    let old: [OldRow]
    let filesTable = NSTableView()
    let oldTable = NSTableView()
    let approveButton: NSButton
    let blockersLabel = NSTextField(labelWithString: "")
    let acknowledgeBox = NSButton(
        checkboxWithTitle: "I've read what the check found; approve anyway", target: nil,
        action: nil)
    /// The old files ticked to lose, by their path on the share.
    private(set) var ticked: Set<String> = []
    /// The approved import; nil for Cancel.
    private(set) var result: ApprovedImport?

    init(plan: ApprovalPlan, album: String) {
        self.plan = plan
        files = Self.fileRows(plan)
        old = Self.oldRows(plan)
        approveButton = NSButton(
            title: plan.resuming ? DownloadAction.resumeHere.title : "Approve", target: nil,
            action: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: plan.isUpgrade ? 560 : 420),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 600, height: 320)
        super.init(window: window)
        build(in: window, album: album)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    // MARK: - The rows

    /// Each staged file, in release order, with its destination and the check's finding. The
    /// check reads the first and last file only, so the rest say so.
    static func fileRows(_ plan: ApprovalPlan) -> [FileRow] {
        let destinations = Dictionary(
            plan.moves.map { ($0.name, $0.destination) }, uniquingKeysWith: { one, _ in one })
        let prefix = plan.libraryFolder.isEmpty ? nil : plan.libraryFolder + "/"
        return plan.job.files.map { file in
            var destination = destinations[file.name] ?? ""
            if let prefix, destination.hasPrefix(prefix) {
                destination.removeFirst(prefix.count)
            }
            let (check, warns) = Self.check(file.name, plan)
            return FileRow(name: file.name, destination: destination, check: check, warns: warns)
        }
    }

    /// What the lossy-origin check found of the file `name`.
    private static func check(_ name: String, _ plan: ApprovalPlan) -> (String, Bool) {
        if plan.resuming { return ("", false) }
        if let problem = plan.originsProblem { return ("Not checked: \(problem)", true) }
        guard let origin = plan.origins.first(where: { $0.path.hasSuffix("/" + name) }) else {
            return ("Not checked", false)
        }
        if let failure = origin.failure { return ("Couldn't be analyzed: \(failure)", true) }
        if origin.verdicts.isEmpty { return ("No sign of a lossy origin", false) }
        return (origin.verdicts.map(\.text).joined(separator: "; "), true)
    }

    /// An upgrade's old files, each saying whether a new file takes its place.
    static func oldRows(_ plan: ApprovalPlan) -> [OldRow] {
        let unmatched = Set(plan.unmatched.map(\.sharePath))
        return plan.old.map { file in
            let lone = unmatched.contains(file.sharePath)
            let note =
                !lone
                ? "Replaced by its new file"
                : file.hasStats
                    ? "No new file: tick to delete it with its plays, rating, love and playlist"
                        + " entries"
                    : "No new file: tick to delete it"
            return OldRow(
                sharePath: file.sharePath, path: file.path, position: file.position ?? "",
                note: note, tickable: lone)
        }
    }

    // MARK: - The layout

    private func build(in window: NSWindow, album: String) {
        var views: [NSView] = []
        let heading = NSTextField(
            labelWithString: (plan.resuming ? "Resume the import of " : "Approve ") + album)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.lineBreakMode = .byTruncatingTail
        views.append(heading)
        views.append(secondary(Self.subtitle(plan)))
        if plan.resuming { views.append(note(Self.resumeNote)) }
        if plan.replacesAlbum { views.append(note(Self.replacesAlbumNote)) }
        if !plan.resuming, let problem = plan.movesProblem {
            views.append(warning("The files can't be moved: \(problem)"))
        }

        // A resumed import's files may be in the library by now, so it lists them alone.
        filesTable.addColumn(
            NSUserInterfaceItemIdentifier(Column.name.rawValue), title: TrackColumn.fileName.title,
            width: 220,
            stretches: plan.resuming)
        if !plan.resuming {
            filesTable.addColumn(
                NSUserInterfaceItemIdentifier(Column.destination.rawValue), title: "Moves To",
                width: 320,
                stretches: true)
            filesTable.addColumn(
                NSUserInterfaceItemIdentifier(Column.check.rawValue), title: "Lossy-Origin Check",
                width: 220)
        }
        let filesScroll = filesTable.inListScrollView(source: self)
        views.append(filesScroll)
        var tables = [filesScroll]

        if plan.isUpgrade {
            views.append(sectionHeading("Old files"))
            if let problem = plan.upgradeProblem {
                views.append(warning(problem))
            } else {
                views.append(warning(Self.deleteWarning))
                oldTable.addColumn(
                    NSUserInterfaceItemIdentifier(Column.tick.rawValue), title: "", width: 24)
                oldTable.addColumn(
                    NSUserInterfaceItemIdentifier(Column.old.rawValue),
                    title: TrackColumn.path.title, width: 360,
                    stretches: true)
                oldTable.addColumn(
                    NSUserInterfaceItemIdentifier(Column.position.rawValue),
                    title: TrackColumn.trackNumber.title,
                    width: 50)
                oldTable.addColumn(
                    NSUserInterfaceItemIdentifier(Column.note.rawValue), title: "", width: 320)
                let oldScroll = oldTable.inListScrollView(source: self)
                views.append(oldScroll)
                tables.append(oldScroll)
            }
        }

        if !plan.resuming && plan.originsBlock {
            acknowledgeBox.target = self
            acknowledgeBox.action = #selector(changed)
            views.append(acknowledgeBox)
        }

        blockersLabel.textColor = .secondaryLabelColor
        blockersLabel.lineBreakMode = .byTruncatingTail
        blockersLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        approveButton.target = self
        approveButton.action = #selector(approve)
        let buttons = NSStackView(views: [blockersLabel, NSView(), cancel, approveButton])
        views.append(buttons)

        let page = NSStackView(views: views)
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for view in views where !(view is NSButton) {
            view.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -32).isActive = true
        }
        for scroll in tables { scroll.setContentHuggingPriority(.defaultLow, for: .vertical) }
        if tables.count == 2 {
            tables[0].heightAnchor.constraint(equalTo: tables[1].heightAnchor).isActive = true
        }
        window.contentView = page
    }

    /// "Discogs release 4242 · FLAC 16/44.1, 12 files · Replaces MP3 320".
    static func subtitle(_ plan: ApprovalPlan) -> String {
        ([DownloadRow.releaseName(plan.job.release.releaseID), DownloadRow.format(plan.job)]
            + [DownloadRow.replaces(plan.job)].compactMap { $0 })
            .joined(separator: " · ")
    }

    private var acknowledged: Bool { acknowledgeBox.state == .on }

    private func refresh() {
        let blockers = plan.blockers(ticked: ticked, acknowledgedOrigins: acknowledged)
        blockersLabel.stringValue = blockers.joined(separator: " ")
        blockersLabel.toolTip = blockers.joined(separator: "\n")
        blockersLabel.isHidden = blockers.isEmpty
        approveButton.isEnabled = blockers.isEmpty
        approveButton.keyEquivalent = blockers.isEmpty ? "\r" : ""
    }

    /// Ticks or unticks the old file in `row`; one with a new file has no box.
    func toggleOld(_ row: Int) {
        guard row < old.count, old[row].tickable else { return }
        let path = old[row].sharePath
        if ticked.remove(path) == nil { ticked.insert(path) }
        oldTable.reloadData(
            forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<oldTable.numberOfColumns))
        refresh()
    }

    @objc private func changed() { refresh() }

    @objc private func boxClicked(_ sender: NSButton) { toggleOld(sender.tag) }

    @objc private func cancel() { endSheet() }

    @objc private func approve() {
        guard let approved = plan.approved(ticked: ticked, acknowledgedOrigins: acknowledged)
        else { return }
        result = approved
        endSheet()
    }

    // MARK: - The tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === filesTable ? files.count : old.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let column = tableColumn.flatMap({ Column(rawValue: $0.identifier.rawValue) })
        else { return nil }
        if tableView === filesTable {
            let file = files[row]
            switch column {
            case .name: return cell(file.name, truncating: .byTruncatingMiddle)
            case .destination:
                return cell(file.destination, truncating: .byTruncatingHead)
            case .check:
                let label = cell(file.check, truncating: .byTruncatingTail)
                label.textColor = file.warns ? .systemOrange : .secondaryLabelColor
                return label
            default: return nil
            }
        }
        let file = old[row]
        switch column {
        case .tick:
            guard file.tickable else { return nil }
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(boxClicked))
            box.tag = row
            box.state = ticked.contains(file.sharePath) ? .on : .off
            return box
        case .old: return cell(file.path, truncating: .byTruncatingHead)
        case .position: return cell(file.position, truncating: .byTruncatingTail)
        case .note:
            let label = cell(file.note, truncating: .byTruncatingTail)
            label.textColor = file.tickable ? .systemOrange : .secondaryLabelColor
            return label
        default: return nil
        }
    }

    private func cell(_ text: String, truncating: NSLineBreakMode) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = truncating
        label.toolTip = text.isEmpty ? nil : text
        return label
    }

    private func secondary(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func sectionHeading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func warning(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .systemRed
        return label
    }
}
