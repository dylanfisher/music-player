import CoreGraphics

/// Where a window opens, in screen coordinates (origin bottom left): `saved`, where it was left,
/// on the one of `screens` (their visible frames) that shows the most of it. With none, as the
/// first time it opens or when the display it was on is gone, or with the screens together
/// showing less than half of it, it's centered on `anchorScreen`, at its saved size when
/// `resizable`, else at `size`. A window that isn't `resizable` keeps `size`, under the saved
/// top left, since its content sets its size. Either way it's moved onto its screen, shrunk to
/// fit when `resizable`, and with its top, the title bar, on the screen when it's taller.
public func placedFrame(
    saved: CGRect?, size: CGSize, resizable: Bool, screens: [CGRect], anchorScreen: CGRect
) -> CGRect {
    let overlaps = saved.map { saved in screens.map { ($0, area($0.intersection(saved))) } } ?? []
    let shown =
        saved.map { overlaps.map(\.1).reduce(0, +) * 2 >= area($0) } == true
        ? overlaps.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0 : nil
    guard let saved, let screen = shown else {
        let size = resizable ? saved?.size ?? size : size
        let centered = CGRect(
            x: (anchorScreen.midX - size.width / 2).rounded(),
            y: (anchorScreen.midY - size.height / 2).rounded(), width: size.width,
            height: size.height)
        return fitted(centered, on: anchorScreen, resizable: resizable)
    }
    let frame =
        resizable
        ? saved
        : CGRect(
            x: saved.minX, y: saved.maxY - size.height, width: size.width, height: size.height)
    return fitted(frame, on: screen, resizable: resizable)
}

/// `frame` moved onto `screen`, and shrunk to it when `resizable`. A frame larger than the
/// screen keeps its left and top edges on it.
private func fitted(_ frame: CGRect, on screen: CGRect, resizable: Bool) -> CGRect {
    var frame = frame
    if resizable {
        // Shrunk about its center, which then moves onto the screen.
        let width = min(frame.width, screen.width)
        let height = min(frame.height, screen.height)
        frame = CGRect(
            x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }
    let x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
    let top = min(screen.maxY, max(frame.maxY, screen.minY + frame.height))
    return CGRect(x: x, y: top - frame.height, width: frame.width, height: frame.height)
}

private func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
