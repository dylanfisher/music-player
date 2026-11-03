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

@Test func aRevealInFinderOverridesAnySetFileViewerFinderIncluded() {
    #expect(fileViewerOverride(global: nil) == nil)
    #expect(fileViewerOverride(global: "com.apple.finder") == "")
    #expect(fileViewerOverride(global: "com.dylanfisher.searcher") == "")
}

@Test func theOverrideGoesInTheArgumentDomainInMemory() throws {
    let suite = "music-player-reveal-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let domain = UserDefaults.argumentDomain
    let before = defaults.volatileDomain(forName: domain)
    defer {
        defaults.setVolatileDomain(before, forName: domain)
        defaults.removePersistentDomain(forName: suite)
    }
    keepRevealsInFinder(defaults) { nil }
    #expect(defaults.volatileDomain(forName: domain)[fileViewerKey] == nil)
    keepRevealsInFinder(defaults) { "com.apple.finder" }
    #expect(defaults.string(forKey: fileViewerKey) == "")
    #expect(defaults.persistentDomain(forName: suite)?[fileViewerKey] == nil)
}
