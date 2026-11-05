import Foundation
import Testing

@testable import Settings

private let setting = AppSettings().headerStatusLayout

private func decode(_ json: String) -> Result<BarLayout<HeaderPart>, SettingProblem.Reason> {
    setting.decode(json: (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as Any)
}

@Test func theHeaderDefaultIsTheArtBesideThreeLinesOverTheSeekBar() {
    let layout = BarLayout<HeaderPart>.defaultHeaderStatus
    #expect(setting.defaultValue == layout)
    #expect(
        layout.leading == [
            BarColumn(parts: [.art], width: .fixed(HeaderPart.artPoints), alignment: .leading)
        ])
    #expect(
        layout.center
            == BarColumn(
                parts: [.title, .subtitle, .format, .seek], width: .flexible,
                alignment: .leading, stacks: true))
    #expect(layout.trailing.isEmpty && layout.problems.isEmpty)
    // The title line waits in the builder's tray.
    #expect(!layout.columns.contains { $0.column.parts.contains(.titleLine) })
    #expect(HeaderPart.titleLine.title == "Title Line" && !HeaderPart.titleLine.fillsHeight)
    guard case .barLayout(let bar) = setting.kind else {
        Issue.record("\(setting.kind)")
        return
    }
    #expect(bar.choices.map(\.rawValue) == HeaderPart.allCases.map(\.rawValue))
    #expect(bar.stackTitle == HeaderPart.stackTitle && bar.stackCapPoints == nil)
    #expect(bar.fillsHeight == ["art"])
}

/// The header has its own parts: the status bar's totals and one-line track aren't among them,
/// and its art doesn't stack with others either.
@Test func theHeaderTakesOnlyItsOwnParts() throws {
    for part in ["totals", "track"] {
        let json =
            #"{"leading": [], "center": {"parts": ["\#(part)"], "width": "flexible", "alignment": "center", "stacks": false}, "trailing": []}"#
        guard case .failure(.wrongType) = decode(json) else {
            Issue.record("accepted \(part)")
            continue
        }
    }
    let stacked = BarLayout<HeaderPart>(
        center: BarColumn(
            parts: [.art, .title], width: .flexible, alignment: .leading, stacks: true))
    #expect(stacked.problems == [.stackedPartFillsHeight("Art", .center)])
}

/// Each Custom Status item has its own layout of the header's parts, checked as the status's
/// is, and starts as Swinsian's centered title line over the seek bar.
@Test func eachCustomStatusHasItsOwnCheckedLayout() throws {
    let schema = AppSettings()
    let slots = [
        schema.customStatus1Layout, schema.customStatus2Layout, schema.customStatus3Layout,
    ]
    #expect(Set(slots.map(\.key)).count == 3)
    #expect(slots.map(\.title) == (1...3).map { "Custom Status \($0) Layout" })
    for slot in slots {
        #expect(slot.defaultValue == .defaultCustomStatus)
        #expect(slot.kind == setting.kind)
        let repeated =
            #"{"leading": [], "center": {"parts": ["seek", "seek"], "width": "flexible", "alignment": "center", "stacks": true}, "trailing": []}"#
        let json = try JSONSerialization.jsonObject(with: Data(repeated.utf8))
        guard case .failure(.invalid) = slot.decode(json: json) else {
            Issue.record("\(slot.key) accepted a part twice")
            continue
        }
    }
    let layout = BarLayout<HeaderPart>.defaultCustomStatus
    #expect(layout.leading.isEmpty && layout.trailing.isEmpty && layout.problems.isEmpty)
    #expect(
        layout.center
            == BarColumn(
                parts: [.titleLine, .seek], width: .flexible, alignment: .center, stacks: true))
}
