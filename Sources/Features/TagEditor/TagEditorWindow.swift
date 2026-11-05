import AppKit
import Artwork
import TagWriter

/// An info window: a field per tag, the art with Replace and Remove beside it, and Cancel and
/// Save. It opens at once, before its files are read, saying so, and shows the fields once
/// `load` hands it the tracks. Fields where the tracks differ show "Mixed" until typed in. It
/// edits a `TagEditorModel` and hands back the checked edit. Several can be open at once.
@MainActor
public final class TagEditorWindow: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    /// The files Get Info was asked for, in the selection's order.
    public let paths: [String]
    /// Nil until the files are read.
    public private(set) var model: TagEditorModel?
    public let window: NSWindow
    /// Called with the edit when the user saves. The window stays open until `close()`.
    var saved: (TagEdit) -> Void = { _ in }
    /// Called once when the window closes, by Cancel, its close button or `close()`.
    var closed: () -> Void = {}
    /// The art buttons, which run the registry's Replace Artwork… and Remove Artwork.
    var replaceArtwork: () -> Void = {}
    var removeArtwork: () -> Void = {}

    private var fields: [TagEditField: NSTextField] = [:]
    private let compilationBox = NSButton(
        checkboxWithTitle: TagEditField.compilation.title, target: nil, action: nil)
    private let artView = NSImageView()
    private let artNote = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let problemLabel = NSTextField(labelWithString: "")
    /// Says, as soon as such a field is edited, that saving keeps one of its several values.
    private let collapseLabel = NSTextField(wrappingLabelWithString: "")
    private var isClosed = false

    static let width = 560.0
    static let artPoints = 120.0
    private static let numberWidth = 52.0
    /// Where the next window opens, so each one opens down and to the right of the last.
    private static var nextTopLeft: NSPoint?

    package init(paths: [String]) {
        precondition(!paths.isEmpty, "Get Info opens on at least one track")
        self.paths = paths
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = heading
        window.delegate = self
        window.contentView = makeReading()
        if let content = window.contentView { window.setContentSize(content.fittingSize) }
    }

    /// The file's name, or how many tracks.
    private var heading: String {
        paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) tracks"
    }

    public var isLoaded: Bool { model != nil }

    /// Shows the window in front, a step down and to the right of the last one opened.
    func show(beside parent: NSWindow) {
        if !window.isVisible {
            let start =
                Self.nextTopLeft
                ?? NSPoint(x: parent.frame.minX + 40, y: parent.frame.maxY - 40)
            Self.nextTopLeft = window.cascadeTopLeft(from: start)
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Shows the fields for `model`. A second call, after the files were read again, keeps what
    /// the user typed and the art they chose, and shows the rest as the files hold them now.
    package func load(_ model: TagEditorModel) {
        if var current = self.model {
            current.reread(model.tracks)
            self.model = current
            showValues()
            return
        }
        self.model = model
        window.contentView = makeContent(model)
        if let content = window.contentView { window.setContentSize(content.fittingSize) }
        showValues()
        window.makeFirstResponder(fields[.title])
    }

    func replaceArt(_ image: Data, mimeType: String) {
        model?.replaceArt(image, mimeType: mimeType)
        showArt()
    }

    func removeArt() {
        model?.removeArt()
        showArt()
    }

    func close() {
        window.close()
        // A window never put on screen doesn't send `windowWillClose`.
        windowClosed()
    }

    public func windowWillClose(_ notification: Notification) { windowClosed() }

    private func windowClosed() {
        guard !isClosed else { return }
        isClosed = true
        closed()
    }

    private func makeReading() -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Reading tags…")
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [spinner, label])
        let stack = NSStackView(views: [headingLabel(), row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return stack
    }

    private func headingLabel() -> NSTextField {
        let label = NSTextField(labelWithString: heading)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    private func makeContent(_ model: TagEditorModel) -> NSView {
        let heading = headingLabel()
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

        collapseLabel.textColor = .systemOrange
        collapseLabel.isHidden = true
        let stack = NSStackView(views: [heading, grid, artRow, collapseLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [heading, collapseLabel, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return stack
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func field(_ field: TagEditField, width: Double? = nil) -> NSTextField {
        let view = NSTextField()
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

    /// Puts the model's values in the fields the user hasn't typed in, and the art.
    private func showValues() {
        guard let model else { return }
        for (field, view) in fields where !model.isTyped(field) {
            view.stringValue = model.text(field)
            view.placeholderString = model.isMixed(field) ? mixedPlaceholder : nil
        }
        if !model.isTyped(.compilation) {
            compilationBox.state =
                model.isMixed(.compilation)
                ? .mixed : model.text(.compilation) == "1" ? .on : .off
        }
        showArt()
        showCollapse()
    }

    private func showArt() {
        guard let model else { return }
        // A Retina screen draws two pixels a point.
        artView.image = model.shownArt
            .flatMap { thumbnail(of: $0, maxPixelSize: Int(Self.artPoints) * 2) }
            .map { NSImage(cgImage: $0, size: .zero) }
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
        model?.set(field, view.stringValue)
        showCollapse()
    }

    private func showCollapse() {
        let note = model?.collapseNote
        collapseLabel.stringValue = note ?? ""
        collapseLabel.isHidden = note == nil
    }

    @objc private func compilationChanged() {
        // The mixed state is only where it starts; a click sets the flag for every track.
        if compilationBox.state == .mixed { compilationBox.state = .on }
        model?.set(.compilation, compilationBox.state == .on ? "1" : "")
        showCollapse()
    }

    @objc private func replaceClicked() { replaceArtwork() }
    @objc private func removeClicked() { removeArtwork() }
    @objc private func cancelClicked() { close() }

    @objc private func saveClicked() {
        guard let model else { return }
        do {
            saved(try model.edit())
        } catch {
            problemLabel.stringValue = error.description
            NSSound.beep()
        }
    }
}
