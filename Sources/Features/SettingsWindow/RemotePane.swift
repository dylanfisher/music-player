import AppKit
import CoreImage
import Log
import Settings

private let logger = moduleLogger()

/// Settings ▸ Remote: the web remote's settings, then its code with a QR code of the pairing
/// link and the page's addresses as text, then the paired devices with Forget (ADR 0214).
@MainActor
final class RemotePane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column: String, CaseIterable {
        case name, paired, lastSeen

        var title: String {
            switch self {
            case .name: "Device"
            case .paired: "Paired"
            case .lastSeen: "Last Seen"
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 220
            case .paired: 170
            case .lastSeen: 170
            }
        }
    }

    static let qrPoints: CGFloat = 160

    let model: RemoteModel
    private let settings: GeneralPane
    let codeLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let addressLabel = NSTextField(labelWithString: "")
    let qrView = NSImageView()
    let showCodeButton = NSButton()
    let forgetButton = NSButton()
    let table = NSTableView()
    private var ticks: Timer?
    private var shownLink: String?

    init(model: RemoteModel, settings: GeneralPane) {
        self.model = model
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override func loadView() {
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        codeLabel.setAccessibilityLabel("Pairing code")
        detailLabel.textColor = .secondaryLabelColor
        addressLabel.isSelectable = true
        addressLabel.lineBreakMode = .byTruncatingMiddle
        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.setAccessibilityLabel("QR code of the pairing link")
        showCodeButton.title = "Show New Code"
        showCodeButton.target = self
        showCodeButton.action = #selector(showCode)
        forgetButton.title = "Forget"
        forgetButton.target = self
        forgetButton.action = #selector(forget)
        for button in [showCodeButton, forgetButton] { button.bezelStyle = .rounded }

        for column in Column.allCases {
            let tableColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            table.addTableColumn(tableColumn)
        }
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(AppState().remoteDevices.title)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let codeColumn = NSStackView(views: [codeLabel, detailLabel, addressLabel, showCodeButton])
        codeColumn.orientation = .vertical
        codeColumn.alignment = .leading
        codeColumn.spacing = 8
        let pairing = NSStackView(views: [qrView, codeColumn])
        pairing.alignment = .top
        pairing.spacing = 16
        let devicesTitle = NSTextField(labelWithString: AppState().remoteDevices.title)
        devicesTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let stack = NSStackView(views: [pairing, devicesTitle, scroll, forgetButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let margin = GeneralPane.margin
        stack.edgeInsets = NSEdgeInsets(
            top: margin, left: margin, bottom: margin, right: margin)
        for view in [pairing, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * margin)
                .isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        qrView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: GeneralPane.width),
            qrView.widthAnchor.constraint(equalToConstant: Self.qrPoints),
            qrView.heightAnchor.constraint(equalToConstant: Self.qrPoints),
            scroll.heightAnchor.constraint(equalToConstant: 140),
        ])
        addChild(settings)
        let pane = NSStackView(views: [settings.view, stack])
        pane.orientation = .vertical
        pane.spacing = 0
        view = pane
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        ticks?.invalidate()
        ticks = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.show() }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        ticks?.invalidate()
        ticks = nil
    }

    /// Shows the settings and the pairing as they are now.
    func reload() {
        settings.reload()
        show()
    }

    func focus(_ key: String) { settings.focus(key) }

    private func show() {
        model.refresh()
        codeLabel.stringValue = model.code ?? "––– –––"
        codeLabel.textColor = model.code == nil ? .tertiaryLabelColor : .labelColor
        detailLabel.stringValue = model.detail
        addressLabel.stringValue = model.addresses ?? ""
        addressLabel.isHidden = model.addresses == nil
        showCodeButton.isEnabled = model.canShowCode
        if shownLink != model.pairingLink {
            shownLink = model.pairingLink
            qrView.image = model.pairingLink.flatMap(qrImage)
        }
        let selected = table.selectedRow
        table.reloadData()
        if model.devices.indices.contains(selected) {
            table.selectRowIndexes([selected], byExtendingSelection: false)
        }
        forgetButton.isEnabled = model.devices.indices.contains(table.selectedRow)
    }

    @objc private func showCode() {
        model.showCode()
        show()
    }

    @objc private func forget() {
        do {
            try model.forget(table.selectedRow)
        } catch {
            logger.error("couldn't forget a paired device: \(error)")
            NSAlert(error: error).runModal()
        }
        show()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.devices.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let device = model.devices[row]
        let text =
            switch tableColumn.flatMap({ Column(rawValue: $0.identifier.rawValue) }) {
            case .name, nil: device.name
            case .paired: device.paired
            case .lastSeen: device.lastSeen
            }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        forgetButton.isEnabled = model.devices.indices.contains(table.selectedRow)
    }
}

/// `text` as a QR code at the pane's size, from CoreImage's generator, with sharp modules.
@MainActor
func qrImage(_ text: String) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let code = filter.outputImage, code.extent.width > 0 else { return nil }
    let scale = (RemotePane.qrPoints * 2 / code.extent.width).rounded(.down)
    let scaled = code.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: NSSize(width: RemotePane.qrPoints, height: RemotePane.qrPoints))
    image.addRepresentation(rep)
    return image
}
