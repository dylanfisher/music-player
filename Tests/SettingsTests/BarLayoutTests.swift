import Foundation
import Testing

@testable import Settings

private let setting = AppSettings().statusBarLayout

private func decode(_ json: String) -> Result<BarLayout<StatusPart>, SettingProblem.Reason> {
    setting.decode(
        json: (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as Any)
}

private func column(_ parts: String, _ more: String = "") -> String {
    #"{"parts": [\#(parts)], "width": "flexible", "alignment": "center", "stacks": false\#(more)}"#
}

@Test func aLayoutRoundTripsWithBothKindsOfWidth() throws {
    let layout = BarLayout<StatusPart>(
        leading: [BarColumn(parts: [.art, .track], width: .fixed(240), alignment: .leading)],
        center: BarColumn(parts: [.seek], width: .flexible, alignment: .center),
        trailing: [
            BarColumn(
                parts: [.format, .totals], width: .flexible, alignment: .trailing, stacks: true)
        ])
    let data = try JSONEncoder().encode(layout)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.contains(#""width":240"#) && text.contains(#""width":"flexible""#))
    #expect(try decode(text).get() == layout)
}

@Test func theDefaultIsTheTotalsAloneInAFlexibleCenteredColumn() throws {
    let layout = BarLayout<StatusPart>.defaultStatusBar
    #expect(layout.leading.isEmpty && layout.trailing.isEmpty)
    #expect(layout.center == BarColumn(parts: [.totals], width: .flexible, alignment: .center))
    #expect(setting.defaultValue == layout)
    #expect(layout.problems.isEmpty)
}

/// An unknown key fails at the layout and at each column, and so does a width that is neither
/// a number nor "flexible", a missing key and an unknown part.
@Test func decodingRejectsUnknownKeysAndValuesAtEveryLevel() {
    let bad = [
        #"{"leading": [], "center": \#(column(#""totals""#)), "trailing": [], "middle": []}"#,
        #"{"leading": [\#(column(#""art""#, #", "gap": 4"#))], "center": \#(column(#""totals""#)), "trailing": []}"#,
        #"{"leading": [], "center": \#(column(#""totals""#, #", "grow": 1"#)), "trailing": []}"#,
        #"{"leading": [], "center": \#(column(#""lyrics""#)), "trailing": []}"#,
        #"{"leading": [], "center": {"parts": ["totals"], "width": "wide", "alignment": "center", "stacks": false}, "trailing": []}"#,
        #"{"leading": [], "center": {"parts": ["totals"], "width": 12.5, "alignment": "center", "stacks": false}, "trailing": []}"#,
        #"{"leading": [], "center": {"parts": ["totals"], "width": "flexible", "alignment": "middle", "stacks": false}, "trailing": []}"#,
        #"{"leading": [], "center": {"parts": ["totals"], "width": "flexible", "alignment": "center"}, "trailing": []}"#,
        #"{"center": \#(column(#""totals""#)), "trailing": []}"#,
        #"["totals"]"#,
    ]
    for json in bad {
        guard case .failure(.wrongType) = decode(json) else {
            Issue.record("accepted \(json)")
            continue
        }
    }
}

@Test func everyProblemIsReportedWithItsColumn() {
    let layout = BarLayout<StatusPart>(
        leading: [
            BarColumn(parts: [], width: .flexible, alignment: .leading),
            BarColumn(parts: [.art, .track], width: .fixed(8), alignment: .leading, stacks: true),
        ],
        center: BarColumn(parts: [.track], width: .flexible, alignment: .center),
        trailing: [BarColumn(parts: [.seek], width: .fixed(5000), alignment: .trailing)])
    #expect(
        layout.problems == [
            .emptyColumn(.leading(0)),
            .widthOutOfRange(.leading(1), points: 8),
            .stackedPartFillsHeight("art", .leading(1)),
            .repeatedPart("track", .center),
            .widthOutOfRange(.trailing(0), points: 5000),
        ])
    guard case .failure(.invalid(let why)) = setting.decode(json: layout.json) else {
        Issue.record("a layout with problems was accepted")
        return
    }
    #expect(why.contains("leading column 1 has no parts"))
    #expect(why.contains("track is listed again in the center column"))
}

@Test func columnsAreListedLeftToRightWithTheirPlaces() {
    let layout = BarLayout<StatusPart>(
        leading: [BarColumn(parts: [.art], width: .flexible, alignment: .leading)],
        center: BarColumn(parts: [.seek], width: .flexible, alignment: .center),
        trailing: [BarColumn(parts: [.totals], width: .flexible, alignment: .trailing)])
    #expect(layout.columns.map(\.place) == [.leading(0), .center, .trailing(0)])
    #expect(layout[.trailing(0)]?.parts == [.totals])
    #expect(layout[.trailing(1)] == nil)
}

extension BarLayout<StatusPart> {
    /// The layout as JSONSerialization gives it, as the config file's value is.
    fileprivate var json: Any {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as Any
    }
}
