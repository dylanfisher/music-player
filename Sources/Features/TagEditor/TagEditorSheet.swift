import AppKit
import TagWriter

/// The tag editor: a sheet with a field per tag, the art with Replace and Remove beside it, and
/// Cancel and Save. Fields where the tracks differ show "Mixed" until typed in. It edits a
/// `TagEditorModel` and hands back the checked edit.
@MainActor
public final class TagEditorSheet: NSObject, NSTextFieldDelegate {
    public private(set) var model: TagEditorModel
    public let window: NSWindow
    /// Called with the edit when the user saves; the sheet has closed.
    public var saved: (TagEdit) -> Void = { _ in }
    /// The art buttons, which run the registry's Replace Artwork… and Remove Artwork.
    public var replaceArtwork: () -> Void = {}
    public var removeArtwork: () -> Void = {}

    private var fields: [TagEditField: NSTextField] = [:]
    private let compilationBox = NSButton(
        checkboxWithTitle: TagEditField.compilation.title, target: nil, action: nil)
    private let artView = NSImageView()
    private let artNote = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let problemLabel = NSTextField(labelWithString: "")

    static let width = 560.0
    static let artPoints = 120.0
    private static let numberWidth = 52.0

    public init(model: TagEditorModel) {
        self.model = model
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 420),
            styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.contentView = makeContent()
        if let content = window.contentView { window.setContentSize(content.fittingSize) }
        showArt()
    }

    public func begin(over parent: NSWindow) {
        parent.beginSheet(window)
        window.makeFirstResponder(fields[.title])
    }

    public func replaceArt(_ image: Data, mimeType: String) {
        model.replaceArt(image, mimeType: mimeType)
        showArt()
    }

    public func removeArt() {
        model.removeArt()
        showArt()
    }

    private func makeContent() -> NSView {
        let heading = NSTextField(
            labelWithString: model.tracks.count == 1
                ? (model.tracks[0].path as NSString).lastPathComponent
                : "\(model.tracks.count) tracks")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.lineBreakMode = .byTruncatingMiddle

        let textFields: [TagEditField] = [
            .title, .artist, .album, .albumArtist, .genre, .date, .composer, .comment,
        ]
        var rows: [[NSView]] = textFields.map { [label($0.title), field($0)] }
        let numbers = NSStackView(views: [
            field(.trackNumber, width: Self.numberWidth), label(TagEditField.trackTotal.title),
            field(.trackTotal, width: Self.numberWidth), label(TagEditField.discNumber.title),
            field(.discNumber, width: Self.numberWidth), label(TagEditField.discTotal.title),
            field(.discTotal, width: Self.numberWidth),
        ])
        rows.append([label(TagEditField.trackNumber.title), numbers])
        compilationBox.allowsMixedState = true
        compilationBox.state =
            model.isMixed(.compilation) ? .mixed : model.text(.compilation) == "1" ? .on : .off
        compilationBox.target = self
        compilationBox.action = #selector(compilationChanged)
        rows.append([NSGridCell.emptyContentView, compilationBox])
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6

        artView.imageScaling = .scaleProportionallyUpOrDown
        artView.imageFrameStyle = .grayBezel
        artView.widthAnchor.constraint(equalToConstant: Self.artPoints).isActive = true
        artView.heightAnchor.constraint(equalToConstant: Self.artPoints).isActive = true
        artNote.textColor = .secondaryLabelColor
        let replace = NSButton(title: "Replace…", target: self, action: #selector(replaceClicked))
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        let artButtons = NSStackView(views: [artNote, replace, removeButton])
        artButtons.orientation = .vertical
        artButtons.alignment = .leading
        let artRow = NSStackView(views: [artView, artButtons])
        artRow.alignment = .top

        problemLabel.textColor = .systemRed
        problemLabel.lineBreakMode = .byWordWrapping
        problemLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        problemLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [problemLabel, cancel, save])

        let stack = NSStackView(views: [heading, grid, artRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [heading, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return stack
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func field(_ field: TagEditField, width: Double? = nil) -> NSTextField {
        let view = NSTextField()
        view.stringValue = model.text(field)
        view.placeholderString = model.isMixed(field) ? mixedPlaceholder : nil
        view.delegate = self
        view.lineBreakMode = .byTruncatingTail
        if let width {
            view.alignment = .right
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        } else {
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        }
        fields[field] = view
        return view
    }

    private func showArt() {
        artView.image = model.shownArt.flatMap(NSImage.init(data:))
        artNote.stringValue =
            switch model.art {
            case .replaced: "New artwork"
            case .removed: "Artwork removed"
            case .unchanged:
                model.isArtMixed ? mixedPlaceholder : model.shownArt == nil ? "No artwork" : ""
            }
        removeButton.isEnabled = model.canRemoveArt
    }

    public func controlTextDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextField,
            let field = fields.first(where: { $0.value === view })?.key
        else { return }
        model.set(field, view.stringValue)
    }

    @objc private func compilationChanged() {
        // The mixed state is only where it starts; a click sets the flag for every track.
        if compilationBox.state == .mixed { compilationBox.state = .on }
        model.set(.compilation, compilationBox.state == .on ? "1" : "")
    }

    @objc private func replaceClicked() { replaceArtwork() }
    @objc private func removeClicked() { removeArtwork() }
    @objc private func cancelClicked() { close() }

    @objc private func saveClicked() {
        do {
            let edit = try model.edit()
            close()
            saved(edit)
        } catch {
            problemLabel.stringValue = error.description
            NSSound.beep()
        }
    }

    private func close() {
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
    }
}
