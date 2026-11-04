import AppKit
import Foundation
import Testing

@testable import Settings
@testable import SettingsWindow

/// The builder's window for `setting`, holding `layout`.
@MainActor
private func window<Part: BarPart>(
    _ setting: Setting<BarLayout<Part>>, _ layout: BarLayout<Part>
) throws -> BarBuilderWindow {
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(layout))
    let model = GeneralModel(
        settings: [setting.descriptor], searcherInstalled: true, value: { _ in json },
        set: { _, _ in }, isBlocked: { false })
    return BarBuilderWindow(model: try model.barBuilder(setting.key))
}

/// The toolbar status's default stacks four parts, which its preview shows whole; the status
/// bar's preview stops at the tall style's cap.
@MainActor @Test func eachBarsPreviewGrowsToItsOwnCap() throws {
    let header = try window(AppSettings().headerStatusLayout, .defaultHeaderStatus)
    let chips = 4 * (BarBuilderView.chipPoints + 4)
    #expect(header.preview.barHeight >= chips, "\(header.preview.barHeight)")
    let stacked = BarLayout<StatusPart>(
        center: BarColumn(
            parts: [.track, .format, .seek, .totals], width: .flexible, alignment: .center,
            stacks: true))
    let status = try window(AppSettings().statusBarLayout, stacked)
    #expect(
        status.preview.barHeight == StatusBarStyle.tallMaxPoints + BarBuilderView.handlePoints)
}

@MainActor @Test func eachBarSaysWhatItsStackingAndCenterDo() throws {
    let header = try window(AppSettings().headerStatusLayout, .defaultHeaderStatus)
    #expect(header.stacks.title == "Stack Parts")
    #expect(header.message.stringValue.hasSuffix(HeaderPart.centerHelp))
    #expect(!header.message.stringValue.contains("window"))
    let status = try window(AppSettings().statusBarLayout, .defaultStatusBar)
    #expect(status.stacks.title == "Stack in Tall Style")
    #expect(status.message.stringValue.hasSuffix("centered on the window."))
}
