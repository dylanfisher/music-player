import AppKit
import Testing

@testable import NowPlaying
@testable import Settings

private let width = 420.0

/// A status with a track's text in it, laid out as `layout` says at `width`.
@MainActor
private func status(_ layout: BarLayout<HeaderPart> = .defaultHeaderStatus) -> HeaderStatus {
    let status = HeaderStatus()
    status.apply(layout)
    status.titleLabel.stringValue = "A Title"
    status.subtitleLabel.stringValue = "An Artist — An Album"
    status.formatLabel.stringValue = "44.1 kHz 16-bit FLAC"
    status.seekBox.showTimes(elapsed: "1:10", total: "3:20")
    status.view.frame = NSRect(x: 0, y: 0, width: width, height: status.view.fittingSize.height)
    status.view.layoutSubtreeIfNeeded()
    return status
}

/// The header as phase 35 built it, by hand: the art, then the three lines over the seek bar
/// across the rest. The default layout has to put every part where this does.
@MainActor
private func phase35Header(like status: HeaderStatus) -> (NSView, [HeaderPart: NSView]) {
    let art = NSView()
    let labels = [status.titleLabel, status.subtitleLabel, status.formatLabel].map { label in
        let copy = NSTextField(labelWithString: label.stringValue)
        copy.font = label.font
        copy.lineBreakMode = .byTruncatingTail
        copy.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return copy
    }
    let seek = SeekBox()
    seek.showTimes(elapsed: "1:10", total: "3:20")
    let text = NSStackView(views: labels)
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 1
    let middle = NSStackView(views: [text, seek])
    middle.orientation = .vertical
    middle.alignment = .leading
    middle.spacing = 2
    for view in [text, seek] {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: middle.widthAnchor).isActive = true
    }
    let detailed = NSStackView(views: [art, middle])
    detailed.spacing = 10
    detailed.alignment = .centerY
    art.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        middle.topAnchor.constraint(greaterThanOrEqualTo: detailed.topAnchor),
        middle.bottomAnchor.constraint(lessThanOrEqualTo: detailed.bottomAnchor),
        art.widthAnchor.constraint(equalToConstant: 48),
        art.heightAnchor.constraint(equalToConstant: 48),
    ])
    detailed.distribution = .fill
    detailed.setClippingResistancePriority(.required, for: .vertical)
    middle.setHuggingPriority(.init(1), for: .horizontal)
    art.setContentHuggingPriority(.required, for: .horizontal)
    detailed.frame = NSRect(x: 0, y: 0, width: width, height: detailed.fittingSize.height)
    detailed.layoutSubtreeIfNeeded()
    return (
        detailed,
        [.art: art, .title: labels[0], .subtitle: labels[1], .format: labels[2], .seek: seek]
    )
}

@MainActor
private func frame(_ view: NSView, in root: NSView) -> NSRect {
    view.convert(view.bounds, to: root)
}

@MainActor @Test func theDefaultLayoutIsTheDetailedHeaderAsItWas() {
    let status = status()
    let (old, oldParts) = phase35Header(like: status)
    #expect(status.view.fittingSize.height == old.fittingSize.height)
    for part in HeaderPart.allCases where ![.titleLine, .rating].contains(part) {
        let now = frame(status.view(for: part), in: status.view)
        let before = frame(oldParts[part]!, in: old)
        #expect(now.minX == before.minX && now.minY == before.minY, "\(part): \(now) \(before)")
        #expect(now.height == before.height, "\(part): \(now) \(before)")
    }
    // The labels as wide as their text, which they were drawn at, and the seek bar across.
    let seek = frame(status.seekBox, in: status.view)
    #expect(seek.width == frame(oldParts[.seek]!, in: old).width)
    #expect(abs(seek.maxX - width) < 0.01, "\(seek) \(frame(oldParts[.seek]!, in: old))")
}

/// The owner's other layout: the title over the artist centered in the status, and the seek
/// bar under them, with the art and the format left out.
@MainActor @Test func aCenteredLayoutCentersOnTheStatus() {
    let layout = BarLayout<HeaderPart>(
        center: BarColumn(
            parts: [.title, .subtitle, .seek], width: .flexible, alignment: .center, stacks: true))
    let status = status(layout)
    for part in [HeaderPart.title, .subtitle] {
        let label = frame(status.view(for: part), in: status.view)
        #expect(abs(label.midX - width / 2) < 1, "\(part) \(label)")
    }
    let seek = frame(status.seekBox, in: status.view)
    #expect(seek.minX == 0 && seek.maxX == width)
    #expect(status.art.superview == nil && status.formatLabel.superview == nil)
}

/// A fixed center column centers on the status whatever the sides hold, until it would
/// overlap one.
@MainActor @Test func aFixedCenterColumnCentersBesideTheArt() {
    let layout = BarLayout<HeaderPart>(
        leading: [BarColumn(parts: [.art], width: .fixed(48), alignment: .leading)],
        center: BarColumn(parts: [.seek], width: .fixed(200), alignment: .center),
        trailing: [BarColumn(parts: [.format], width: .flexible, alignment: .trailing)])
    let status = status(layout)
    let seek = frame(status.seekBox, in: status.view)
    #expect(abs(seek.midX - width / 2) < 1 && seek.width == 200, "\(seek)")
    #expect(frame(status.art, in: status.view).minX == 0)
    let format = frame(status.formatLabel, in: status.view)
    #expect(status.formatLabel.alignmentRect(forFrame: format).maxX <= width, "\(format)")
}

/// Side by side, a column's parts keep the row's spacing, however a stacked layout spaced them
/// before.
@MainActor @Test func anUnstackedColumnPutsItsPartsSideBySide() {
    let status = status()
    status.apply(
        BarLayout(
            center: BarColumn(
                parts: [.title, .format], width: .flexible, alignment: .leading, stacks: false)))
    status.view.layoutSubtreeIfNeeded()
    let title = status.titleLabel.alignmentRect(
        forFrame: frame(status.titleLabel, in: status.view))
    let format = status.formatLabel.alignmentRect(
        forFrame: frame(status.formatLabel, in: status.view))
    #expect(abs(format.minX - title.maxX - HeaderStatus.spacingPoints) < 0.5, "\(title) \(format)")
    #expect(abs(format.midY - title.midY) < 1)
}

/// An empty column takes its width and draws nothing, so the parts beside it move over.
@MainActor @Test func anEmptyColumnKeepsItsWidth() {
    let status = status(
        BarLayout(
            leading: [BarColumn(parts: [], width: .fixed(60), alignment: .leading)],
            center: BarColumn(
                parts: [.title, .seek], width: .flexible, alignment: .leading, stacks: true)))
    let seek = frame(status.seekBox, in: status.view)
    #expect(abs(seek.minX - 60 - HeaderStatus.spacingPoints) < 0.5, "\(seek)")
    #expect(abs(seek.maxX - width) < 0.01)
}

/// The title line is one line, which truncates at its tail when the status is too narrow.
@MainActor @Test func theTitleLineTruncatesAtItsTail() {
    let status = HeaderStatus()
    status.apply(
        BarLayout(
            leading: [BarColumn(parts: [.art], width: .fixed(48), alignment: .leading)],
            center: BarColumn(
                parts: [.titleLine, .seek], width: .flexible, alignment: .leading, stacks: true)))
    status.titleLineLabel.stringValue = String(
        repeating: "FI3AC2384210 by Aleksi Perälä ", count: 9)
    status.view.frame = NSRect(x: 0, y: 0, width: width, height: status.view.fittingSize.height)
    status.view.layoutSubtreeIfNeeded()
    let line = status.titleLineLabel.alignmentRect(
        forFrame: frame(status.titleLineLabel, in: status.view))
    #expect(status.titleLineLabel.lineBreakMode == .byTruncatingTail)
    #expect(line.minX == 48 + HeaderStatus.spacingPoints && line.maxX <= width + 0.5, "\(line)")
    #expect(line.height < 2 * status.titleLineLabel.intrinsicContentSize.height)
}

/// A layout of fixed columns is as wide as the columns and the spacing between them, and lays
/// out at that width with each column in its place; a flexible column leaves the width to the
/// room the status is given.
@MainActor @Test func aFixedLayoutIsAsWideAsItsColumns() {
    let spacing = HeaderStatus.spacingPoints
    let layout = BarLayout<HeaderPart>(
        leading: [BarColumn(parts: [.art], width: .fixed(48), alignment: .leading)],
        center: BarColumn(parts: [.seek], width: .fixed(200), alignment: .center),
        trailing: [BarColumn(parts: [], width: .fixed(60), alignment: .leading)])
    let points = 48 + 200 + 60 + 2 * spacing
    #expect(HeaderStatus.fixedWidthPoints(of: layout) == points)
    let alone = BarLayout<HeaderPart>(
        center: BarColumn(parts: [.titleLine], width: .fixed(300), alignment: .center))
    #expect(HeaderStatus.fixedWidthPoints(of: alone) == 300)
    #expect(HeaderStatus.fixedWidthPoints(of: .defaultHeaderStatus) == nil)
    #expect(HeaderStatus.fixedWidthPoints(of: .defaultCustomStatus) == nil)
    let status = HeaderStatus()
    status.apply(layout)
    status.view.frame = NSRect(x: 0, y: 0, width: points, height: status.view.fittingSize.height)
    status.view.layoutSubtreeIfNeeded()
    #expect(frame(status.art, in: status.view).minX == 0)
    let seek = frame(status.seekBox, in: status.view)
    #expect(abs(seek.minX - 48 - spacing) < 0.5 && seek.width == 200, "\(seek)")
}
