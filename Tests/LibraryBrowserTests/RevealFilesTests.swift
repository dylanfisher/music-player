import Foundation
import Settings
import Testing

@testable import LibraryBrowser

private let installed = URL(fileURLWithPath: "/Applications/Searcher.app", isDirectory: true)

@Test func searcherRevealsWhenItsInstalled() {
    var asked: [String] = []
    let app = searcherApp(.searcher) { id in
        asked.append(id)
        return installed
    }
    #expect(app == installed)
    #expect(asked == ["com.dylanfisher.searcher"])
}

@Test func finderRevealsWhenSearcherIsntInstalled() {
    #expect(searcherApp(.searcher) { _ in nil } == nil)
}

@Test func finderRevealsWhenTheSettingSaysFinder() {
    #expect(searcherApp(.finder) { _ in installed } == nil)
}
