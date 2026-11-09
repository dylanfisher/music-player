import Foundation
import Testing

@testable import Downloads
@testable import Recommender

// The speed and time left of a download, from the bytes the service reports and the times the
// player received them, on an injected clock.

private let start = Date(timeIntervalSince1970: 1_794_100_000)
private let mb = 1_000_000

private func downloading(_ bytes: Int, of total: Int = 100 * mb, _ state: JobState = .downloading)
    -> DownloadJob
{
    job(1, state) {
        $0.progress = DownloadJob.Progress(
            filesDone: 1, filesTotal: 12, bytesDone: bytes, bytesTotal: total)
    }
}

@Test func theSpeedIsTheBytesOverTheTimeAcrossTheReadings() throws {
    var rates = TransferRates()
    rates.take([downloading(0)], at: start)
    #expect(rates.rate(1, at: start) == nil, "one reading says nothing")
    rates.take([downloading(10 * mb)], at: start + 5)
    #expect(rates.rate(1, at: start + 5) == nil, "too short a span to trust")
    rates.take([downloading(20 * mb)], at: start + 10)
    let rate = try #require(rates.rate(1, at: start + 10))
    #expect(rate.bytesPerSecond == 2 * Double(mb))
    #expect(rate.secondsLeft == 40)
}

@Test func pollsBetweenTheServicesWritesDontSwingTheSpeed() throws {
    // The service writes every 5 s at 1 MB/s; the player polls every 2 s and sees each write up
    // to 2 s late. Repeats of a value add no reading, so the average stays near the truth.
    var rates = TransferRates()
    let seen: [(TimeInterval, Int)] = [
        (0, 0), (2, 0), (4, 0), (6, 5), (8, 5), (10, 5), (12, 10), (14, 10), (16, 15), (18, 15),
        (20, 15), (22, 20), (24, 20), (26, 25),
    ]
    for (time, megabytes) in seen {
        rates.take([downloading(megabytes * mb)], at: start + time)
    }
    let rate = try #require(rates.rate(1, at: start + 26))
    #expect(abs(rate.bytesPerSecond / Double(mb) - 1) < 0.05)
}

@Test func aStalledReadingHoldsItsSpeedThenShowsNoneNeverZero() throws {
    var rates = TransferRates()
    rates.take([downloading(0)], at: start)
    rates.take([downloading(20 * mb)], at: start + 10)
    // Another job's search holds the download's progress still for over a minute.
    for second in stride(from: 12.0, through: 90, by: 2) {
        rates.take([downloading(20 * mb)], at: start + second)
    }
    let held = try #require(rates.rate(1, at: start + 90))
    #expect(held.bytesPerSecond == 2 * Double(mb))
    rates.take([downloading(20 * mb)], at: start + 131)
    #expect(rates.rate(1, at: start + 131) == nil)
}

@Test func aReadingAfterASearchStallKeepsTheTrueSpeed() throws {
    // slskd goes on downloading at 2 MB/s while the service's search holds its progress still
    // for 70 s; the first reading after it has every byte slskd got meanwhile.
    var rates = TransferRates()
    for second in stride(from: 0, through: 10, by: 5) {
        rates.take(
            [downloading(second * 2 * mb, of: 1000 * mb)], at: start + TimeInterval(second))
    }
    rates.take([downloading(160 * mb, of: 1000 * mb)], at: start + 80)
    let rate = try #require(rates.rate(1, at: start + 80))
    #expect(rate.bytesPerSecond == 2 * Double(mb), "160 MB over 80 s")
}

@Test func theCopyIntoStagingStartsItsOwnReadings() throws {
    var rates = TransferRates()
    rates.take([downloading(0)], at: start)
    rates.take([downloading(100 * mb)], at: start + 10)
    #expect(rates.rate(1, at: start + 10) != nil)
    rates.take([downloading(0, .downloaded)], at: start + 12)
    #expect(rates.rate(1, at: start + 12) == nil)
    rates.take([downloading(40 * mb, .downloaded)], at: start + 22)
    #expect(try #require(rates.rate(1, at: start + 22)).bytesPerSecond == 4 * Double(mb))
    rates.take([job(1, .staged)], at: start + 24)
    #expect(rates.isEmpty)
}

@Test(arguments: [
    (20.0, "less than a minute left"), (61, "about 2 min left"), (180, "about 3 min left"),
    (3600, "about 1 h left"), (3900, "about 1 h 5 min left"),
])
func theTimeLeftIsRoundedUpToTheMinute(seconds: Double, words: String) {
    #expect(TransferRate.left(seconds) == words)
}

@MainActor @Test func theWindowShowsTheSpeedAndForgetsItOnClosing() async throws {
    let service = FakeService([downloading(0)])
    let clock = service.clock
    let model = DownloadsModel(
        service: service.service, machine: "Studio",
        now: { Date(timeIntervalSince1970: clock.now) }, sleep: { try await clock.sleep($0) })
    model.start()
    await eventually("the first poll") { clock.waiting == [60] }
    model.setWindowOpen(true)
    await eventually("a poll on opening") { clock.waiting == [2] }
    service.put(downloading(10 * mb))
    clock.advance(by: 5)
    await eventually("a poll") { service.listed.count == 3 && clock.waiting == [2] }
    service.put(downloading(20 * mb))
    clock.advance(by: 5)
    await eventually("the speed") { model.rows.first?.state.contains("MB/s") == true }
    #expect(model.rows.first?.state.hasPrefix("Downloading, 1 of 12 files · 2") == true)

    model.setWindowOpen(false)
    #expect(model.rows.first?.state == "Downloading, 1 of 12 files")
    model.stop()
}

@MainActor @Test func aClosedWindowTakesNoReadings() async throws {
    let service = FakeService([downloading(0)])
    let clock = service.clock
    let model = DownloadsModel(
        service: service.service, machine: "Studio",
        now: { Date(timeIntervalSince1970: clock.now) }, sleep: { try await clock.sleep($0) })
    model.start()
    await eventually("the first poll") { clock.waiting == [60] }
    for (offset, megabytes) in [10, 20, 30].enumerated() {
        service.put(downloading(megabytes * mb))
        clock.advance(by: 60)
        await eventually("a poll") {
            service.listed.count == offset + 2 && clock.waiting == [60]
        }
    }
    #expect(model.rows.first?.state == "Downloading, 1 of 12 files")
    #expect(model.rows.first?.progress == 0.3)
    model.stop()
}
