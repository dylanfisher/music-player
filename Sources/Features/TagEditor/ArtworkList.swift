import AppKit
import Artwork
import Metadata
import TagWriter
import UniformTypeIdentifiers

/// The Artwork tab's list of pictures: a row each, its thumbnail, a pop-up of its type and its
/// size. Images dropped on it or pasted into it are added, as + adds them (ADR 0172).
@MainActor
final class ArtworkList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = PictureTable()
    /// The pictures listed, as the model last gave them.
    private(set) var pictures: [ArtPicture] = []
    /// Whether pictures can be added, removed and retyped: some file can be saved.
    var isEditable = false
    /// Called with the images dropped or pasted, and what couldn't be read.
    var added: ([(data: Data, mimeType: String)], [String]) -> Void = { _, _ in }
    /// Called with the type chosen for the picture at an index.
    var typeChosen: (PictureType, Int) -> Void = { _, _ in }
    var selectionChanged: () -> Void = {}

    static let rowHeight = 56.0
    private static let thumbnailPoints = 48.0

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("picture"))
        column.title = "Pictures"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes(PictureTable.imageTypes)
        table.pasted = { [weak self] pasteboard in self?.take(pasteboard) }
        table.canPaste = { [weak self] in self?.isEditable == true }
    }

    /// Lists `pictures`, reloading only when they changed, so the selection stays.
    func show(_ pictures: [ArtPicture]) {
        guard pictures != self.pictures else { return }
        self.pictures = pictures
        table.reloadData()
    }

    /// The picture selected first, if any.
    var selected: Int? { table.selectedRowIndexes.first }

    private func take(_ pasteboard: NSPasteboard) {
        let (images, problems) = pictureImages(from: pasteboard)
        guard !images.isEmpty || !problems.isEmpty else { return NSSound.beep() }
        added(images, problems)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { pictures.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard pictures.indices.contains(row) else { return nil }
        let picture = pictures[row]
        let image = NSImageView()
        image.image = thumbnail(of: picture.image, maxPixelSize: Int(Self.thumbnailPoints) * 2)
            .map { NSImage(cgImage: $0, size: .zero) }
        image.imageScaling = .scaleProportionallyUpOrDown
        image.widthAnchor.constraint(equalToConstant: Self.thumbnailPoints).isActive = true
        image.heightAnchor.constraint(equalToConstant: Self.thumbnailPoints).isActive = true
        let type = NSPopUpButton()
        type.controlSize = .small
        type.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        var choices = PictureType.choices
        // A type the menu doesn't offer, as an artist photo, shows as Other until changed.
        if !choices.contains(picture.type) { choices.append(picture.type) }
        for choice in choices {
            type.addItem(withTitle: choice.name)
            type.lastItem?.tag = Int(choice.rawValue)
        }
        type.selectItem(withTag: Int(picture.type.rawValue))
        type.isEnabled = isEditable
        type.tag = row
        type.target = self
        type.action = #selector(typePicked)
        let details = NSTextField(labelWithString: imageDescription(picture.image))
        details.textColor = .secondaryLabelColor
        details.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        details.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [type, details])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        return NSStackView(views: [image, text])
    }

    @objc private func typePicked(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag else { return }
        typeChosen(PictureType(rawValue: UInt32(tag)), sender.tag)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged() }

    func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard isEditable, info.draggingSource as? NSTableView !== table else { return [] }
        // A drop goes on the whole list: an image is added after the rest.
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard isEditable else { return false }
        take(info.draggingPasteboard)
        return true
    }
}

/// The list's table, which takes Paste of images while pictures can be added.
final class PictureTable: NSTableView {
    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
    ]

    var pasted: (NSPasteboard) -> Void = { _ in }
    var canPaste: () -> Bool = { false }

    /// Where Paste reads from; tests give one of their own.
    var pasteboard = NSPasteboard.general

    @objc func paste(_ sender: Any?) { pasted(pasteboard) }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            return canPaste() && pasteboard.availableType(from: Self.imageTypes) != nil
        }
        return super.validateUserInterfaceItem(item)
    }
}

/// The images on `pasteboard` as the writer takes them: files read, or image data, a JPEG or
/// PNG as it is and any other image as PNG; and why each file that isn't one was left out.
func pictureImages(from pasteboard: NSPasteboard) -> (
    images: [(data: Data, mimeType: String)], problems: [String]
) {
    let urls =
        pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    if !urls.isEmpty { return pictureImages(at: urls) }
    for type in PictureTable.imageTypes.dropFirst() {
        if let data = pasteboard.data(forType: type), let image = artImage(data) {
            return ([image], [])
        }
    }
    return ([], [])
}

/// The image files at `urls`, read as `pictureImages(from:)` reads them.
func pictureImages(at urls: [URL]) -> (
    images: [(data: Data, mimeType: String)], problems: [String]
) {
    var images: [(data: Data, mimeType: String)] = []
    var problems: [String] = []
    for url in urls {
        do {
            guard let image = artImage(try Data(contentsOf: url)) else {
                problems.append("\(url.lastPathComponent) isn't an image")
                continue
            }
            images.append(image)
        } catch {
            problems.append("\(url.lastPathComponent): \(error)")
        }
    }
    return (images, problems)
}

/// `data` as a JPEG or PNG, by its signature; another image converted to PNG; nil for none.
func artImage(_ data: Data) -> (data: Data, mimeType: String)? {
    if data.starts(with: [0xFF, 0xD8, 0xFF]) { return (data, jpegMIMEType) }
    if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
        return (data, pngMIMEType)
    }
    guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    else { return nil }
    return (png, pngMIMEType)
}
