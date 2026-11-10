import AppKit
import DisplayText
import Library

/// Organize Selected Files' sheet (ADR 0175): it opens as the command runs and counts the
/// selected tracks with a bar while their tags are read, Cancel stopping the count; once
/// counted it asks "Organize N Files?" with Organize and Cancel.
@MainActor
final class OrganizeSheet: NSWindowController {
    static let countingTitle = "Checking the Selected Tracks…"

    let heading = NSTextField(labelWithString: OrganizeSheet.countingTitle)
    let detail = NSTextField(wrappingLabelWithString: "")
    let bar = NSProgressIndicator()
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let organizeButton = NSButton(title: "Organize", target: nil, action: nil)
    /// Called once, with true for Organize and false for Cancel, whether the count had
    /// finished or not.
    var answered: (Bool) -> Void = { _ in }
    /// Whether the question is up, after which the count's late reports are dropped.
    private(set) var asking = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 150), styleMask: [.titled],
            backing: .buffered, defer: false)
        super.init(window: window)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        detail.preferredMaxLayoutWidth = 420
        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        organizeButton.target = self
        organizeButton.action = #selector(organize)
        organizeButton.keyEquivalent = "\r"
        organizeButton.isHidden = true
        let buttons = NSStackView(views: [NSView(), cancelButton, organizeButton])
        let page = NSStackView(views: [heading, detail, bar, buttons])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        for view in [detail, bar, buttons] {
            view.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -40).isActive = true
        }
        window.contentView = page
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    func begin(over parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
    }

    /// Shows how far the count of `total` tracks has got.
    func counted(_ checked: Int, of total: Int, moving: Int) {
        guard !asking else { return }
        detail.stringValue = organizeCounting(checked: checked, of: total, moving: moving)
        bar.isIndeterminate = false
        bar.doubleValue = total == 0 ? 0 : Double(checked) / Double(total)
    }

    /// Puts the question about `plan` in place of the count, with Organize.
    func ask(_ plan: FilesOrganized) {
        asking = true
        let question = organizeQuestion(plan)
        heading.stringValue = question.message
        detail.stringValue = question.detail
        bar.stopAnimation(nil)
        bar.isHidden = true
        organizeButton.isHidden = false
    }

    /// Closes the sheet, telling `answered` the answer given; with none, as when the count
    /// found nothing to ask about, it's told nothing.
    func end(answering answer: Bool? = nil) {
        if let answer { answered(answer) }
        answered = { _ in }
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }

    @objc private func cancel() { end(answering: false) }

    @objc private func organize() {
        guard asking else { return }
        end(answering: true)
    }
}

/// "Checked 120 of 2,340 tracks · 80 files to rename so far", while Organize Selected Files
/// counts.
func organizeCounting(checked: Int, of total: Int, moving: Int) -> String {
    "Checked \(number(checked)) of \(tracks(total)) · \(files(moving)) to rename so far"
}
