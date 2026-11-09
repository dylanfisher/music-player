import AppKit
import Foundation
import Testing

@testable import Downloads
@testable import Recommender
@testable import Settings

// The status bar's downloads item: what it says of the jobs on their way, each style, and its
// click and right-click.

private func downloading(_ id: Int, bytes: Int, created: Int) -> DownloadJob {
    job(id, .downloading, created: created) {
        $0.progress = DownloadJob.Progress(
            filesDone: 1, filesTotal: 4, bytesDone: bytes, bytesTotal: 100)
    }
}

@Test func onlyTheJobsOnTheirWayShowAndTheyHideWithNone() {
    #expect(DownloadsStatus([job(1, .staged), job(2, .notFound), job(3, .failed)]) == nil)
    #expect(DownloadsStatus([]) == nil)
}

@Test func theStatusCountsTheAlbumsAndAveragesHowFarTheyGot() throws {
    let status = try #require(
        DownloadsStatus([
            downloading(1, bytes: 50, created: 1), job(2, .searching, created: 2),
            job(3, .downloaded, created: 3), job(4, .staged),
        ]))
    #expect(status.albums == 3)
    #expect(status.fraction == 0.5)
    #expect(status.text(.count) == "3")
    #expect(status.text(.progress) == "3")
    #expect(status.text(.label) == "Downloading 3 albums, 50%")
    #expect(
        status.tooltip
            == [
                "Made-Up Artist - Made-Up Album (1999): Copying to staging…",
                "Made-Up Artist - Made-Up Album (1999): Searching…",
                "Made-Up Artist - Made-Up Album (1999): Downloading, 1 of 4 files",
                "", DownloadsStatus.help,
            ].joined(separator: "\n"))
}

@MainActor
@Test func eachStyleShowsItsViews() throws {
    let item = DownloadsStatusItem()
    #expect(item.isHidden)
    let status = try #require(DownloadsStatus([downloading(1, bytes: 25, created: 1)]))
    item.show(status, style: .progress)
    #expect(!item.isHidden && !item.bar.isHidden && item.image.isHidden)
    #expect(item.bar.doubleValue == 0.25 && item.label.stringValue == "1")
    item.show(status, style: .count)
    #expect(item.bar.isHidden && !item.image.isHidden && item.label.stringValue == "1")
    item.show(status, style: .label)
    #expect(item.bar.isHidden && !item.image.isHidden)
    #expect(item.label.stringValue == "Downloading 1 album, 25%")
    item.show(nil, style: .label)
    #expect(item.isHidden)
}

@MainActor
@Test func aRightClickPicksTheStyleWithTheCurrentOneTicked() throws {
    let item = DownloadsStatusItem()
    var chosen: [DownloadsStatusStyle] = []
    item.styleChosen = { chosen.append($0) }
    item.show(DownloadsStatus([job(1, .queued)]), style: .count)
    let event = try #require(
        NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let menu = try #require(item.menu(for: event))
    #expect(menu.items.map(\.title) == DownloadsStatusStyle.allCases.map(\.title))
    #expect(menu.items.map(\.state) == [.on, .off, .off])
    item.chose(menu.items[2])
    #expect(chosen == [.progress])
}

@MainActor
@Test func startingWithTheStatusBarInViewPollsOnce() async throws {
    let service = FakeService([downloading(1, bytes: 10, created: 1)])
    let (downloads, session) = try await started(service.service, statusBarShown: true) {
        throw CancellationError()
    }
    #expect(session.model.isStatusShown)
    await eventually("the first poll") { !service.listed.isEmpty }
    for _ in 0..<2_000 { await Task.yield() }
    #expect(service.listed.count == 1)
    downloads.stop()
}

@MainActor
@Test func theItemFollowsThePollsAndItsClickOpensTheWindow() async throws {
    let service = FakeService([downloading(1, bytes: 10, created: 1)])
    let (downloads, session) = try await started(service.service) {
        throw CancellationError()
    }
    downloads.statusStyle = .label
    downloads.setStatusBarShown(true)
    #expect(session.model.isStatusShown)
    await eventually("the item") { !downloads.statusItem.isHidden }
    #expect(downloads.statusItem.label.stringValue == "Downloading 1 album, 10%")
    service.put(job(1, .staged))
    await session.model.poll()
    #expect(downloads.statusItem.isHidden)
    downloads.statusItem.clicked()
    #expect(downloads.window?.isVisible == true)
    downloads.window?.close()
    downloads.stop()
}
