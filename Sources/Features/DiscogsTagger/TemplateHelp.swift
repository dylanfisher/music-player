import AppKit
import Settings

/// What Field Mapping's template help (51.25) says: how a template is filled, and every token
/// one can name, from the list the mapping's check accepts.
enum TemplateHelp {
    /// Each token a template can name, with what it stands for.
    static var tokens: [(token: String, meaning: String)] {
        DiscogsMapping.templateNames.map { token in
            let field = DiscogsField.allCases.first { $0.token == token }
            return (token, field?.title ?? "The first genre alone")
        }
    }

    static let examples = [
        (
            template: "{genre} - {styles}",
            result: "Electronic - Dub Techno, Techno, with a Join of \", \""
        ),
        (template: "{catalogNumber} ({country})", result: "SK 2 (Sweden)"),
    ]

    static var text: String {
        let rules = [
            "A template builds the tag from Discogs fields. Each token in braces is replaced by"
                + " that field's value; text outside braces is kept as written. A field with no"
                + " value leaves its token empty.",
            "A list field in a template, such as {styles}, is joined with this row's Join.",
        ]
        let examples = Self.examples.map { "\($0.template)  →  \($0.result)" }
        let tokens = Self.tokens.map { "\($0.token)  \($0.meaning)" }
        return
            (rules + ["Examples:\n" + examples.joined(separator: "\n")]
            + ["Tokens:\n" + tokens.joined(separator: "\n")])
            .joined(separator: "\n\n")
    }

    /// A popover of the help, scrolled to its start.
    @MainActor
    static func popover() -> NSPopover {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 440, height: 420)
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.drawsBackground = false
        scroll.drawsBackground = false
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        view.string = text
        let controller = NSViewController()
        controller.view = scroll
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = scroll.frame.size
        return popover
    }
}
