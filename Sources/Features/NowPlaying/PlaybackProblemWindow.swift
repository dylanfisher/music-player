import AppKit
import Foundation
import Log
import Playback

private let logger = moduleLogger()

/// The details of the playback problem the status bar shows: what went wrong, the track and
/// its format, the output device and its format, hog mode, the error's full text and the
/// playback modules' recent log lines, with Copy for a bug report, and the problem's fix as a
/// button when it has one (ADR 0111).
@MainActor
public final class PlaybackProblemWindow: NSObject {
    let window: NSPanel
    let headline = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSTextView.scrollableTextView()
    /// The report's text, which can be selected and copied.
    let details: NSTextView
    let copyButton = NSButton(title: "Copy Details", target: nil, action: nil)
    let fixButton = NSButton(title: "", target: nil, action: nil)
    /// Called with the fix the button makes and the problem it fixes, whose track may play again.
    public var fixRequested: (PlaybackFix, ShownProblem) -> Void = { _, _ in }
    private(set) var report: ProblemReport?
    /// Where Copy puts the text; tests give it a pasteboard of their own.
    var pasteboard = NSPasteboard.general
    /// Reads the log lines off the main thread; tests replace it.
    var readLog: @Sendable () throws -> [String] = {
        try recentLogLines(
            categories: ProblemReport.logCategories, seconds: ProblemReport.logSeconds)
    }

    override public init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered,
            defer: true)
        details = scroll.documentView as! NSTextView
        super.init()
        headline.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        details.isEditable = false
        details.isRichText = false
        details.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        details.textContainerInset = NSSize(width: 4, height: 4)
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        copyButton.target = self
        copyButton.action = #selector(copy(_:))
        fixButton.target = self
        fixButton.action = #selector(fix)
        let bar = NSStackView(views: [fixButton, copyButton])
        bar.detachesHiddenViews = true
        let stack = NSStackView(views: [headline, scroll, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for view in [headline, scroll] {
            view.widthAnchor.constraint(
                equalTo: stack.widthAnchor,
                constant: -stack.edgeInsets.left - stack.edgeInsets.right
            ).isActive = true
        }
        window.title = "Playback Problem"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        // A panel hides with the app by default; the details stay up while the owner files a report.
        window.hidesOnDeactivate = false
        window.center()
    }

    /// Shows `report` and brings the window forward, then reads the log lines into it.
    public func show(_ report: ProblemReport) {
        show(report, logLines: nil)
        window.makeKeyAndOrderFront(nil)
        let read = readLog
        Task {
            let lines = await Task.detached {
                do {
                    return try read()
                } catch {
                    logger.error("couldn't read the log for a problem's details: \(error)")
                    return ["The log couldn't be read: \(error)"]
                }
            }.value
            // Another problem may have opened meanwhile.
            guard self.report?.shown == report.shown else { return }
            self.show(report, logLines: lines)
        }
    }

    private func show(_ report: ProblemReport, logLines: [String]?) {
        var report = report
        report.logLines = logLines
        self.report = report
        headline.stringValue = report.shown.headline
        details.string = report.text
        let fix = report.shown.problem.fix
        fixButton.isHidden = fix == nil
        fixButton.title = fix?.buttonTitle ?? ""
    }

    @objc private func fix() {
        guard let shown = report?.shown, let fix = shown.problem.fix else { return }
        fixRequested(fix, shown)
    }

    @objc func copy(_ sender: Any?) {
        guard let report else { return NSSound.beep() }
        pasteboard.clearContents()
        pasteboard.setString(report.text, forType: .string)
    }
}
