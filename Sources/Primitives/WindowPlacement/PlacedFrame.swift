import CoreGraphics

/// Where a window opens, in screen coordinates (origin bottom left): `saved`, where it was left,
/// when one of `screens` (their visible frames) shows part of it, as one doesn't when the
/// display it was on is gone. A window that isn't `resizable` keeps `size` there, with the
/// saved top left, since its content sets its size. Otherwise, as the first time it opens,
/// `size` centered on `anchorScreen`, shrunk to fit it when `resizable`.
func placedFrame(
    saved: CGRect?, size: CGSize, resizable: Bool, screens: [CGRect], anchorScreen: CGRect
) -> CGRect {
    if let saved, screens.contains(where: { $0.intersects(saved) }) {
        guard !resizable else { return saved }
        return CGRect(
            x: saved.minX, y: saved.maxY - size.height, width: size.width, height: size.height)
    }
    let width = resizable ? min(size.width, anchorScreen.width) : size.width
    let height = resizable ? min(size.height, anchorScreen.height) : size.height
    return CGRect(
        x: (anchorScreen.midX - width / 2).rounded(), y: (anchorScreen.midY - height / 2).rounded(),
        width: width, height: height)
}
