/// The window a tag edit was made in, which the journal keeps with the edit so Undo Tag Edit
/// can ask before undoing another window's edit (ADR 0136).
public enum TagEditOrigin: String, Sendable {
    /// Get Info's windows, and the main window they open over.
    case tagEditor
    case discogsTagger
}
