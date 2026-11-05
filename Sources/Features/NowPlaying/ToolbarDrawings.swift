import AppKit
import Settings

extension NowPlayingBar {
    /// The status's width in its drawing, in points.
    static let drawingWidthPoints = 240.0
    /// How much smaller than the toolbar's status its drawing is.
    static let drawingScale = 0.7

    /// The transport as the customization sheet shows it: the same buttons, wired to nothing.
    public static func transportDrawing() -> NSView {
        let buttons = [NSButton(), NSButton(), NSButton()]
        setUpTransport(buttons[0], buttons[1], buttons[2])
        let stack = NSStackView(views: buttons)
        stack.spacing = 4
        return stack
    }

    /// The now-playing status, or a Custom Status item, as the customization sheet shows it:
    /// `layout`'s parts with a placeholder track, its title line as `titleFormat` writes it, and
    /// a seek bar part played, at the width the toolbar shows it at its narrowest.
    public static func statusDrawing(
        _ layout: BarLayout<HeaderPart>, titleFormat: TitleTemplate
    ) -> NSView {
        guard
            let note = NSImage(
                systemSymbolName: "music.quarternote.3", accessibilityDescription: nil)
        else { preconditionFailure("SF Symbols has no music.quarternote.3") }
        let drawing = HeaderStatus()
        drawing.apply(layout)
        drawing.art.image = note
        drawing.art.contentTintColor = .secondaryLabelColor
        let title = "Song Title"
        let format = "44.1 kHz 16-bit FLAC"
        drawing.titleLabel.stringValue = title
        drawing.titleLineLabel.stringValue = titleFormat.fill { token in
            switch token {
            case .title: title
            case .artist: "The Artist"
            case .album: "The Album"
            case .format: format
            case .albumArtist, .composer, .genre, .year, .trackNumber, .discNumber: nil
            }
        }
        drawing.subtitleLabel.stringValue = "Artist — Album"
        drawing.formatLabel.stringValue = format
        drawing.seekBox.bar.fraction = 0.35
        drawing.seekBox.showTimes(elapsed: "1:10", total: "3:20")
        // Drawn smaller, since the sheet's default set is about as tall as a button's row.
        // A layout of fixed columns is drawn at its own width, as a Custom Status item is sized.
        let width = HeaderStatus.fixedWidthPoints(of: layout) ?? drawingWidthPoints / drawingScale
        let size = NSSize(width: width, height: drawing.view.fittingSize.height)
        drawing.view.frame = NSRect(origin: .zero, size: size)
        let shown = NSSize(width: width * drawingScale, height: size.height * drawingScale)
        // The frame first: the bounds' scale is their size against it, and a later frame
        // change keeps the scale.
        let scaled = NSView(frame: NSRect(origin: .zero, size: shown))
        scaled.setBoundsSize(size)
        scaled.addSubview(drawing.view)
        scaled.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scaled.widthAnchor.constraint(equalToConstant: shown.width),
            scaled.heightAnchor.constraint(equalToConstant: shown.height),
        ])
        return scaled
    }
}
