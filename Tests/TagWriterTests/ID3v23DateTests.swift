import Foundation
import Testing

@testable import Metadata
@testable import TagWriter

private func datedFile() throws -> URL {
    try mp3(
        withTag: id3Tag([
            id3TextFrame("TIT2", "Dated"), id3TextFrame("TYER", "1997"),
            id3TextFrame("TDAT", "1205"), id3TextFrame("TIME", "1430"),
        ]))
}

@Test func aV23YearDayAndTimeReadAsOneDate() throws {
    #expect(try tags(datedFile()).date == "1997-05-12T14:30")
}

@Test(arguments: ["2001", "2001-02-03", "2001-02-03T04:05", ""])
func aV23DateIsWrittenAsYearDayAndTime(_ date: String) throws {
    let url = try datedFile()
    let original = try Data(contentsOf: url)
    let writer = scratchWriter()
    expectChanged(writer.write(TagEdit(values: [.date: date]), to: [url.path]), [url])
    #expect(try tags(url).date == date.nilIfEmpty)
    let ids = try readTagLayout(at: url).blocks.map(\.path)
    #expect(!ids.contains("ID3/TDRC"))
    #expect(ids.contains("ID3/TYER") == !date.isEmpty)
    #expect(ids.contains("ID3/TDAT") == (date.count >= 10))
    #expect(ids.contains("ID3/TIME") == (date.count == 16))
    expectChanged(writer.undoLast(), [url])
    #expect(try Data(contentsOf: url) == original)
}

@Test(arguments: ["2001-02", "May 1997", "2001-02-03 04:05"])
func aDateV23CantHoldIsRefused(_ date: String) throws {
    let url = try datedFile()
    let original = try Data(contentsOf: url)
    let report = scratchWriter().write(TagEdit(values: [.date: date]), to: [url.path])
    #expect(report.failures.map(\.kind) == [.unsupported])
    #expect(report.failures.first?.detail.contains("ID3v2.3") == true)
    #expect(try Data(contentsOf: url) == original)
}

@Test func anotherEditKeepsTheDayAndTime() throws {
    let url = try datedFile()
    let pristine = try scratchCopy(of: url)
    let edit = TagEdit(values: [.title: "Retitled"])
    expectChanged(scratchWriter().write(edit, to: [url.path]), [url])
    #expect(try untouchedBlockDifferences(original: pristine, edited: url, edit: edit) == [])
    #expect(try tags(url).date == "1997-05-12T14:30")
}
