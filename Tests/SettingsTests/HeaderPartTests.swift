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
    guard case .barLayout(let bar) = setting.kind else {
        Issue.record("\(setting.kind)")
        return
    }
    #expect(bar.choices.map(\.rawValue) == HeaderPart.allCases.map(\.rawValue))
    #expect(bar.stackTitle == HeaderPart.stackTitle && bar.stackCapPoints == nil)
}

/// The header has its own parts: the status bar's totals and one-line track aren't among them,
/// and its art doesn't stack either.
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
    #expect(stacked.problems == [.stackedPartFillsHeight("art", .center)])
}
