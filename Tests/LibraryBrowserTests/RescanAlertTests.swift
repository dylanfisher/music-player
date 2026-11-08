import AppKit
import Library
import Testing

@testable import LibraryBrowser

/// The titles of the buttons and the texts of the sheet over `window`.
@MainActor private func sheetTitles(over window: NSWindow) throws -> [String] {
    let sheet = try #require(window.attachedSheet, "no sheet")
    var views = [try #require(sheet.contentView)]
    var titles: [String] = []
    while let view = views.popLast() {
        if let button = view as? NSButton { titles.append(button.title) }
        if let field = view as? NSTextField { titles.append(field.stringValue) }
        views += view.subviews
    }
    return titles
}

@MainActor @Test func aChangeWhileRunningAsksOverTheWindowWithCancel() async throws {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)
    let notice = RescanNotice(separatingReleases: true)
    for (button, rescan) in [
        (NSApplication.ModalResponse.alertFirstButtonReturn, true),
        (.alertSecondButtonReturn, false),
    ] {
        var answers: [Bool] = []
        askToRescan(notice, over: window) { answers.append($0) }
        let titles = try sheetTitles(over: window)
        #expect(titles.contains("Rescan Now") && titles.contains("Cancel"))
        #expect(!titles.contains("Quit"))
        #expect(titles.contains(notice.text))
        window.endSheet(try #require(window.attachedSheet), returnCode: button)
        try await waitFor("the answer") { !answers.isEmpty }
        #expect(answers == [rescan])
    }
}
