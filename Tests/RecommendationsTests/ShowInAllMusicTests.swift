import AppKit
import Foundation
import Testing

@testable import Library
@testable import Recommendations
@testable import Recommender

// Show in All Music: for a row whose release Downloads imported, the album the files brought,
// found by the release they carry.

@MainActor
@Test func showInAllMusicAppliesToARowWhoseDownloadWasImported() throws {
    let window = RecommendationsWindow()
    window.show(
        rows: [album(7), album(8)].map { RecommendationRow(album: $0) },
        query: RecommendationQuery(), seeds: [], pending: false, message: nil, action: nil,
        facts: nil)
    window.show(downloads: [1007: "Completed", 1008: "Queued"], imported: [1007: 1007])
    var chosen: [Int] = []
    window.allMusicChosen = { chosen.append($0.album.id) }
    #expect(!window.allMusicButton.isEnabled, "nothing selected")
    window.table.selectRowIndexes([1], byExtendingSelection: false)
    #expect(!window.allMusicButton.isEnabled, "queued, not imported")
    window.table.selectRowIndexes([0], byExtendingSelection: false)
    #expect(window.allMusicButton.isEnabled)
    window.allMusicButton.performClick(nil)
    #expect(chosen == [7])
    window.show(downloads: [:], imported: [:])
    #expect(!window.allMusicButton.isEnabled, "the job no longer listed")
    window.window?.close()
}

/// Release 1007's files were tagged as 2007; release 1008 was imported but no album carries
/// it now.
@MainActor
@Test func showInAllMusicShowsTheAlbumTheFilesCarryOrSaysItIsntThere() async {
    let recommendations = Recommendations(
        databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent(
            "unused-\(UUID().uuidString).sqlite", isDirectory: false))
    let asked = Asked()
    recommendations.albumOfRelease = { release in
        asked.add(release)
        return release == 2007 ? 70 : nil
    }
    var shown: [Int64] = []
    recommendations.showInAllMusic = { shown.append($0) }
    recommendations.show(downloads: [:], imported: [1007: 2007, 1008: 1008])
    #expect(recommendations.showInLibrary(RecommendationRow(album: album(9))) == nil)
    await recommendations.showInLibrary(RecommendationRow(album: album(7)))?.value
    #expect(shown == [70])
    #expect(recommendations.model.notice == nil)
    await recommendations.showInLibrary(RecommendationRow(album: album(8)))?.value
    #expect(shown == [70])
    #expect(recommendations.model.notice == LibraryIndex.releaseNotInLibrary(1008))
    #expect(asked.releases == [2007, 1008])
    await recommendations.showInLibrary(RecommendationRow(album: album(7)))?.value
    #expect(recommendations.model.notice == nil, "its own notice taken back")
    recommendations.model.show(notice: "Couldn't mark the album: refused")
    await recommendations.showInLibrary(RecommendationRow(album: album(7)))?.value
    #expect(recommendations.model.notice == "Couldn't mark the album: refused", "another's kept")
}

/// The releases a stand-in lookup was asked for.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [Int] = []

    func add(_ release: Int) { lock.withLock { asked.append(release) } }
    var releases: [Int] { lock.withLock { asked } }
}

/// The action buttons and the search field all show at the window's smallest width.
@MainActor
@Test func theActionsFitTheSmallestWindow() throws {
    let window = RecommendationsWindow()
    let smallest = try #require(window.window?.minSize.width)
    let actions = try #require(window.allMusicButton.superview)
    #expect(actions.fittingSize.width + 28 <= smallest)
    window.window?.close()
}
