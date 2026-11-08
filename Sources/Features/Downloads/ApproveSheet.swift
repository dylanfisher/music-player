import AppKit
import Analysis
import Library

/// Approve… (54.13, ADR 0139): what moves where; for an upgrade, the old files deleted, which
/// on a share with no Trash is for good, and the old files with no new one, each ticked to lose;
/// and the lossy-origin check, acknowledged when it found anything. Approve stays off until
/// nothing blocks it, then ends the sheet with `result` set.
@MainActor
final class ApproveSheet: NSWindowController {
    /// Said plainly, since the owner's library share has no Trash.
    static let deleteWarning =
        "These old files are deleted. On a share with no Trash, such as the NAS, they're deleted"
        + " permanently."

    let plan: ApprovalPlan
    let approveButton: NSButton
    let blockersLabel = NSTextField(wrappingLabelWithString: "")
    let acknowledgeBox = NSButton(
        checkboxWithTitle: "I've read what the check found; approve anyway", target: nil,
        action: nil)
    private(set) var unmatchedBoxes: [NSButton] = []
    /// The approved import; nil for Cancel.
    private(set) var result: ApprovedImport?

    init(plan: ApprovalPlan, album: String) {
        self.plan = plan
        approveButton = NSButton(
            title: plan.resuming ? DownloadAction.resumeHere.title : "Approve", target: nil, action: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 560, height: 380)
        super.init(window: window)
        build(in: window, album: album)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    private func build(in window: NSWindow, album: String) {
        var views: [NSView] = []
        let title = NSTextField(
            labelWithString: (plan.resuming ? "Resume the import of " : "Approve ") + album)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        title.lineBreakMode = .byTruncatingTail
        views.append(title)
        views.append(secondary(DownloadRow.releaseName(plan.job.release.releaseID)))

        if plan.resuming {
            views.append(
                NSTextField(
                    wrappingLabelWithString:
                        "The import stopped partway. It goes on from where the library and the"
                        + " import's record say it got to."))
        } else if let problem = plan.movesProblem {
            views.append(warning("The files can't be moved: \(problem)"))
        } else {
            views.append(
                NSTextField(
                    labelWithString:
                        "Moves \(plan.moves.count) file\(plan.moves.count == 1 ? "" : "s") into the library:"))
            views.append(lines(plan.moves.map { "\($0.name)  →  \($0.destination)" }, height: 110))
        }

        if plan.isUpgrade {
            if let problem = plan.upgradeProblem {
                views.append(warning(problem))
            } else {
                views.append(warning(Self.deleteWarning))
                views.append(lines(plan.old.map(\.path), height: 90))
                if !plan.unmatched.isEmpty {
                    views.append(
                        NSTextField(
                            wrappingLabelWithString:
                                "These old files have no new one at their place on the release."
                                + " Tick each to delete it with its plays, rating, love and"
                                + " playlist entries:"))
                    for file in plan.unmatched {
                        let box = NSButton(
                            checkboxWithTitle: file.path + (file.hasStats ? " (has stats)" : ""),
                            target: self, action: #selector(changed))
                        box.lineBreakMode = .byTruncatingMiddle
                        unmatchedBoxes.append(box)
                        views.append(box)
                    }
                }
            }
        }

        if !plan.resuming {
            views.append(NSTextField(labelWithString: "Lossy-origin check:"))
            views.append(lines(Self.originLines(plan), height: 54))
            if plan.originsBlock {
                acknowledgeBox.target = self
                acknowledgeBox.action = #selector(changed)
                views.append(acknowledgeBox)
            }
        }

        blockersLabel.textColor = .systemOrange
        views.append(blockersLabel)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        approveButton.target = self
        approveButton.action = #selector(approve)
        let buttons = NSStackView(views: [NSView(), cancel, approveButton])
        views.append(buttons)

        let page = NSStackView(views: views)
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 8
        page.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for view in views where !(view is NSButton) {
            view.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -32).isActive = true
        }
        window.contentView = page
    }

    /// A line per analyzed file: fine, what it shows, or why it couldn't be read.
    static func originLines(_ plan: ApprovalPlan) -> [String] {
        if let problem = plan.originsProblem { return ["The check couldn't run: \(problem)"] }
        return plan.origins.map { origin in
            let name = (origin.path as NSString).lastPathComponent
            if let failure = origin.failure { return "\(name): couldn't be analyzed: \(failure)" }
            if origin.verdicts.isEmpty { return "\(name): no sign of a lossy origin" }
            return "\(name): " + origin.verdicts.map(\.text).joined(separator: "; ")
        }
    }

    var ticked: Set<String> {
        Set(
            zip(plan.unmatched, unmatchedBoxes).filter { $0.1.state == .on }.map(\.0.sharePath))
    }

    private var acknowledged: Bool { acknowledgeBox.state == .on }

    private func refresh() {
        let blockers = plan.blockers(ticked: ticked, acknowledgedOrigins: acknowledged)
        blockersLabel.stringValue = blockers.joined(separator: " ")
        blockersLabel.isHidden = blockers.isEmpty
        approveButton.isEnabled = blockers.isEmpty
    }

    @objc private func changed() { refresh() }

    @objc private func cancel() { endSheet() }

    @objc private func approve() {
        guard let approved = plan.approved(ticked: ticked, acknowledgedOrigins: acknowledged)
        else { return }
        result = approved
        endSheet()
    }

    private func secondary(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func warning(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .systemRed
        return label
    }

    /// `text`, a line each, in a read-only scrolling view `height` points high.
    private func lines(_ text: [String], height: CGFloat) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            view.string = text.joined(separator: "\n")
        }
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }
}
