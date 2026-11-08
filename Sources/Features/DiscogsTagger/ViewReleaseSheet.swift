import AppKit
import Discogs
import DisplayText

/// View Release… (51.37, after YATE's release view): a release of Other Releases… before it's
/// used, its label, catalog number, format, country and year over its tracklist as Discogs
/// lists it, with Open on Discogs.
@MainActor
final class ViewReleaseSheet: NSWindowController, TaggerSheet, NSTableViewDataSource,
    NSTableViewDelegate
{
    let release: ReleaseDetail
    let heading = NSTextField(labelWithString: "")
    let line = NSTextField(labelWithString: "")
    let table = NSTableView()
    static let layoutKind = TaggerSheetKind.viewRelease

    init(release: ReleaseDetail) {
        self.release = release
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 420, height: 300)
        super.init(window: window)
        build(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    /// The release's page on Discogs.
    var discogsURL: URL { discogsPage(release.summary.id) }

    private func build(in window: NSWindow) {
        let summary = release.summary
        heading.stringValue = "\(summary.artist) – \(summary.title)"
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.lineBreakMode = .byTruncatingTail
        line.stringValue = [
            summary.label, summary.catalogNumber, summary.format, summary.country, summary.year,
        ]
        .filter { !$0.isEmpty }.joined(separator: " · ")
        line.textColor = .secondaryLabelColor
        line.lineBreakMode = .byTruncatingTail
        let scroll = taggerTable(
            table, [(.position, 56), (.title, 320), (.releaseTime, 56)], source: self)
        let open = NSButton(title: openOnDiscogsTitle, target: self, action: #selector(open))
        let done = NSButton(title: "Close", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [open, NSView(), done])
        let page = NSStackView(views: [heading, line, scroll, buttons])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for view in [scroll, buttons] {
            view.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -32).isActive = true
        }
        window.contentView = page
    }

    func numberOfRows(in tableView: NSTableView) -> Int { release.tracks.count }

    /// The text of the cell in column `id` of `row`.
    func text(_ id: TaggerColumn, _ row: Int) -> String {
        let track = release.tracks[row]
        switch id {
        case .position: return track.position
        case .title: return track.title
        default: return track.seconds.map { clock(Double($0)) } ?? ""
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let id = tableColumn.flatMap({ TaggerColumn(rawValue: $0.identifier.rawValue) })
        else { return nil }
        let cell = NSTextField(labelWithString: text(id, row))
        cell.lineBreakMode = .byTruncatingTail
        // A heading has neither a position nor a length.
        if release.tracks[row].position.isEmpty, release.tracks[row].seconds == nil {
            cell.textColor = .secondaryLabelColor
        }
        return cell
    }

    @objc private func open() { NSWorkspace.shared.open(discogsURL) }

    @objc private func done() { endSheet() }
}
