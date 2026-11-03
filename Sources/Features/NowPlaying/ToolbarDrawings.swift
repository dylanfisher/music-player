import AppKit

extension NowPlayingBar {
    /// The status's width in its drawing, in points.
    static let drawingWidthPoints = 240.0
    static let drawingArtPoints = 32.0

    /// The transport as the customization sheet shows it: the same buttons, wired to nothing.
    public static func transportDrawing() -> NSView {
        let buttons = [NSButton(), NSButton(), NSButton()]
        setUpTransport(buttons[0], buttons[1], buttons[2])
        let stack = NSStackView(views: buttons)
        stack.spacing = 4
        return stack
    }

    /// The now-playing status as the customization sheet shows it: art, a title, an artist and
    /// album, and a seek bar part played, at the size the toolbar shows it at its narrowest.
    public static func statusDrawing() -> NSView {
        let art = NSImageView(
            image: NSImage(systemSymbolName: "music.quarternote.3", accessibilityDescription: nil)
                ?? NSImage())
        art.wantsLayer = true
        art.layer?.cornerRadius = 3
        art.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        art.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: "Song Title")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Artist — Album")
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor
        let bar = SeekBar()
        bar.fraction = 0.35
        let text = NSStackView(views: [title, subtitle, bar])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let drawing = NSStackView(views: [art, text])
        drawing.spacing = 8
        for view in [art, bar, drawing] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            art.widthAnchor.constraint(equalToConstant: drawingArtPoints),
            art.heightAnchor.constraint(equalToConstant: drawingArtPoints),
            bar.widthAnchor.constraint(equalTo: text.widthAnchor),
            drawing.widthAnchor.constraint(equalToConstant: drawingWidthPoints),
        ])
        return drawing
    }
}
