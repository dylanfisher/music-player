import AppKit

/// A split view that records whether the user is dragging its divider, so the browser saves a
/// height only from a drag. Layout passes resize the subviews too, to 0 when the timeline hides
/// the whole split, and those sizes aren't the user's. `mouseDown` tracks the drag until the
/// mouse goes up.
final class DividerDragSplitView: NSSplitView {
    var isDragging = false

    /// Fits the subviews to the split after one hid or showed, and the divider with them: the
    /// split draws it in a layer of its own, over the subviews, which adjusting leaves where it
    /// was, a line over the rows once the slot above them hides. Only layout moves it.
    func adjustSubviewsAndDivider() {
        adjustSubviews()
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        defer { isDragging = false }
        super.mouseDown(with: event)
    }
}
