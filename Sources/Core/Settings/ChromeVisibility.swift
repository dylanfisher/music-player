/// Which of the main window's toolbar, sidebar and status bar show, and Distraction-Free Mode,
/// which hides them all and then puts back what showed.
public struct ChromeVisibility: Equatable, Sendable {
    public var toolbar: Bool
    public var sidebar: Bool
    public var statusBar: Bool

    public init(toolbar: Bool, sidebar: Bool, statusBar: Bool) {
        self.toolbar = toolbar
        self.sidebar = sidebar
        self.statusBar = statusBar
    }

    public static let hidden = ChromeVisibility(toolbar: false, sidebar: false, statusBar: false)
    public static let shown = ChromeVisibility(toolbar: true, sidebar: true, statusBar: true)

    /// What Distraction-Free Mode shows next, from what shows now and what it hid last, which it
    /// updates: with anything showing, nothing, remembering what showed; with nothing showing,
    /// what it hid, or everything when it hid nothing, as after a relaunch with all hidden.
    public func toggled(hid: inout ChromeVisibility?) -> ChromeVisibility {
        guard self == .hidden else {
            hid = self
            return .hidden
        }
        defer { hid = nil }
        return hid ?? .shown
    }
}
