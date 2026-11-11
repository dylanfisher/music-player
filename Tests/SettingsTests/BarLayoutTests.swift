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
            .widthOutOfRange(.leading(1), points: 8),
            .stackedPartFillsHeight("Art", .leading(1)),
            .repeatedPart("Title and Artist", .center),
            .widthOutOfRange(.trailing(0), points: 5000),
        ])
    guard case .failure(.invalid(let why)) = setting.decode(json: layout.json) else {
        Issue.record("a layout with problems was accepted")
        return
    }
    #expect(why.contains("the second column on the left is 8 points wide"))
    #expect(why.hasSuffix("; 1 more"), "the rest are counted")
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

/// Widths that aren't whole points in range, however large or odd, fail rather than wrap.
@Test func hugeAndOddWidthsAreRefused() {
    for width in ["1e300", "1e400", "99999999999999999999", "-1e30", "\"NaN\"", "null", "true"] {
        guard case .failure(.wrongType) = decode(widthJSON(width)) else {
            Issue.record("accepted width \(width)")
            continue
        }
    }
    let nan: [String: Any] = [
        "leading": [] as [Any], "trailing": [] as [Any],
        "center": [
            "parts": ["totals"], "width": NSNumber(value: Double.nan), "alignment": "center",
            "stacks": false,
        ] as [String: Any],
    ]
    if case .success = setting.decode(json: nan) { Issue.record("accepted a NaN width") }
    guard case .failure(.invalid) = decode(widthJSON("-5")) else {
        Issue.record("accepted a negative width")
        return
    }
}

private func widthJSON(_ width: String) -> String {
    #"{"leading": [], "center": {"parts": ["totals"], "width": \#(width), "alignment": "center", "stacks": false}, "trailing": []}"#
}

/// A layout with many problems lists the first few and how many more.
@Test func manyProblemsAreCappedWithACount() {
    let narrow = BarColumn<StatusPart>(parts: [], width: .fixed(2), alignment: .leading)
    let layout = BarLayout(
        leading: Array(repeating: narrow, count: 5),
        center: BarColumn(parts: [.totals], width: .flexible, alignment: .center))
    #expect(layout.problems.count == 5)
    let text = layout.problem() ?? ""
    #expect(text.contains("the third column on the left is 2 points wide"))
    #expect(!text.contains("fourth"))
    #expect(text.hasSuffix("; 2 more"))
}

/// Problems read as plain sentences, naming the part by its title and the column by where it
/// is, each side counted left to right.
@Test func problemsReadInPlainWords() {
    let art = BarLayoutProblem.stackedPartFillsHeight(StatusPart.art.title, .center)
    #expect(
        "\(art)"
            == "Art is as tall as the bar, so it can't stack with other parts in the center column")
    let width = BarLayoutProblem.widthOutOfRange(.trailing(1), points: 2)
    #expect(
        "\(width)"
            == "the second column on the right is 2 points wide, but a fixed width is 16 to 1200 points"
    )
    #expect("\(BarPlace.leading(0))" == "the first column on the left")
    #expect("\(BarPlace.leading(10))" == "the 11th column on the left")
    #expect("\(BarPlace.trailing(21))" == "the 22nd column on the right")
}

/// The art alone in a stacked column has nothing to stack with, so only sharing it is a
/// problem.
@Test func theArtStacksOnlyAlone() {
    var layout = BarLayout<StatusPart>(
        leading: [BarColumn(parts: [.art], width: .fixed(48), alignment: .leading, stacks: true)],
        center: BarColumn(parts: [.totals], width: .flexible, alignment: .center))
    #expect(layout.problems.isEmpty)
    layout.leading[0].parts.append(.track)
    #expect(layout.problems == [.stackedPartFillsHeight("Art", .leading(0))])
}

/// The playing track's rating is a part, written by its name and read back.
@Test func theRatingRoundTripsAsAPart() throws {
    let layout = BarLayout<StatusPart>(
        leading: [BarColumn(parts: [.track, .rating], width: .flexible, alignment: .leading)],
        center: BarColumn(parts: [.totals], width: .flexible, alignment: .center))
    let text = try #require(String(data: try JSONEncoder().encode(layout), encoding: .utf8))
    #expect(text.contains(#""parts":["track","rating"]"#))
    #expect(try decode(text).get() == layout)
    let written = #"{"leading": [], "center": \#(column(#""rating""#)), "trailing": []}"#
    #expect(try decode(written).get().center.parts == [.rating])
    #expect(StatusPart.rating.title == "Rating" && !StatusPart.rating.fillsHeight)
}
