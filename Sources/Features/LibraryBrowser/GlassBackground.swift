import AppKit

/// `content` on liquid glass from macOS 26, and on the title bar's material before it, filling
/// the view returned.
@MainActor
func glassBackground(around content: NSView) -> NSView {
    let background: NSView
    if #available(macOS 26, *) {
        let glass = NSGlassEffectView()
        // A bar across the window's width, so square like the window's edge.
        glass.cornerRadius = 0
        glass.contentView = content
        background = glass
    } else {
        let material = NSVisualEffectView()
        material.material = .titlebar
        material.blendingMode = .withinWindow
        material.addSubview(content)
        background = material
    }
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        content.topAnchor.constraint(equalTo: background.topAnchor),
        content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
    ])
    return background
}
