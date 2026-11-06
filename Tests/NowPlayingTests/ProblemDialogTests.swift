import AppKit
import Artwork
import Foundation
import Testing

@testable import Library
@testable import NowPlaying
@testable import Playback

private struct NoHogMode: PlaybackFailure {
    var description: String { "cannotPlayDSD(noHogMode)" }
    var userMessage: String {
        "ADI-2 DAC can't play DSD64: DoP needs exclusive access, and hog mode is off for this device"
    }
    var fix: PlaybackFix? { .turnOnHogMode(deviceUID: "ADI-2") }
}

private struct Damaged: PlaybackFailure {
    var description: String { "/m/a.flac: bad frame" }
    var userMessage: String { "the file is damaged" }
}

private let urls = ["/m/a.dsf", "/m/b.flac"].map { URL(fileURLWithPath: $0, isDirectory: false) }

private func update(_ event: PlaybackEvent) -> PlaybackUpdate {
    var state = PlaybackState()
    state.queue = urls
    state.order = [0, 1]
    state.currentIndex = 0
    return PlaybackUpdate(state: state, event: event)
}

@MainActor private func bar() -> NowPlayingBar {
    NowPlayingBar(
        model: NowPlayingModel { _ in nil }, artwork: ArtworkLoader(maxPixelSize: 8, capacity: 1))
}

@Test func aFixableProblemsDialogSaysWhyAndOffersTheFix() throws {
    let shown = ShownProblem(
        problem: PlaybackProblem(NoHogMode()), track: urls[0], entry: 0, trackFormat: "DSD64",
        headline: "Couldn't play a.dsf")
    let dialog = try #require(ProblemDialog(shown))
    #expect(dialog.title == "DSD needs exclusive access to the device")
    #expect(
        dialog.text
            == "ADI-2 DAC can't play DSD64: DoP needs exclusive access, and hog mode is off for"
            + " this device. Turn on hog mode for this device to play it. While the app plays,"
            + " other apps can't play through the device.")
    #expect(dialog.buttons == [.fix(.turnOnHogMode(deviceUID: "ADI-2")), .cancel])
    #expect(dialog.buttons.map(\.title) == ["Turn On Hog Mode", "Cancel"])
    var damaged = shown
    damaged.problem = PlaybackProblem(Damaged())
    #expect(ProblemDialog(damaged) == nil)
}

private func inARow(_ problems: [PlaybackProblem]) -> ShownProblem {
    let tracks = zip(urls + urls, problems).enumerated().map {
        FailedTrack(url: $1.0, entry: $0 % urls.count, problem: $1.1)
    }
    let problem = PlaybackProblem(PlaybackError.failedInARow(tracks))
    return ShownProblem(
        problem: problem, track: urls[0], entry: 0, trackFormat: nil,
        headline: "Playback stopped: \(problem.message)")
}

/// Tracks failing in a row for one reason say it, with its fix when there is one; for
/// several, each with its count, and a button for the details.
@Test func tracksFailingInARowSayWhyInTheirDialog() throws {
    let hog = try #require(
        ProblemDialog(inARow(Array(repeating: PlaybackProblem(NoHogMode()), count: 3))))
    #expect(hog.title == "3 tracks in a row couldn't play")
    #expect(hog.text.hasPrefix("ADI-2 DAC can't play DSD64: DoP needs exclusive access"))
    #expect(
        hog.text.hasSuffix(
            "Turn on hog mode for this device to play it. While the app plays, other apps can't play through the device."
        ))
    #expect(hog.buttons == [.fix(.turnOnHogMode(deviceUID: "ADI-2")), .cancel])

    let damaged = try #require(
        ProblemDialog(inARow(Array(repeating: PlaybackProblem(Damaged()), count: 3))))
    #expect(damaged.text == "The file is damaged." && damaged.buttons == [.ok])

    let mixed = try #require(
        ProblemDialog(
            inARow([
                PlaybackProblem(NoHogMode()), PlaybackProblem(Damaged()),
                PlaybackProblem(NoHogMode()),
            ])))
    #expect(mixed.title == "3 tracks in a row couldn't play")
    #expect(
        mixed.text.components(separatedBy: "\n") == [
            "2 tracks: ADI-2 DAC can't play DSD64: DoP needs exclusive access, and hog mode is off"
                + " for this device.",
            "1 track: The file is damaged.",
        ])
    #expect(mixed.buttons.map(\.title) == ["Show Details", "OK"])

    // Causes that differ but share one fix offer it beside the details.
    var elsewhere = PlaybackProblem(NoHogMode())
    elsewhere.message = "hog mode is off for the other device"
    let shared = try #require(ProblemDialog(inARow([PlaybackProblem(NoHogMode()), elsewhere])))
    #expect(shared.buttons == [.fix(.turnOnHogMode(deviceUID: "ADI-2")), .details, .cancel])
}

/// A problem with a fix, or tracks failing in a row, shows its dialog as it happens; another
/// problem shows only in the status bar.
@MainActor @Test func theBarShowsADialogForAFixOrTracksFailingInARow() {
    let bar = bar()
    var shown: [ProblemDialog] = []
    bar.showDialog = { shown.append($0) }
    bar.apply(update(.trackFailed(urls[1], entry: 1, PlaybackProblem(Damaged()))))
    #expect(shown.isEmpty)
    bar.apply(update(.trackFailed(urls[0], entry: 0, PlaybackProblem(NoHogMode()))))
    #expect(shown.map(\.shown.track) == [urls[0]])
    let stopped = inARow(Array(repeating: PlaybackProblem(Damaged()), count: 3))
    bar.apply(update(.failed(stopped.problem)))
    #expect(shown.count == 2 && shown.last?.buttons == [.ok])
    #expect(shown.last?.shown.headline == stopped.headline)
}

@MainActor @Test func theDetailsWindowOffersTheFixAsAButton() {
    let window = PlaybackProblemWindow()
    window.readLog = { [] }
    var asked: [(PlaybackFix, ShownProblem)] = []
    window.fixRequested = { asked.append(($0, $1)) }
    let fixable = ShownProblem(
        problem: PlaybackProblem(NoHogMode()), track: urls[0], entry: 0, trackFormat: "DSD64",
        headline: "Couldn't play a.dsf")
    window.show(ProblemReport(fixable, path: nil, hogMode: false))
    #expect(!window.fixButton.isHidden && window.fixButton.title == "Turn On Hog Mode")
    window.fixButton.performClick(nil)
    #expect(
        asked.map(\.0) == [.turnOnHogMode(deviceUID: "ADI-2")] && asked.first?.1.track == urls[0])
    var damaged = fixable
    damaged.problem = PlaybackProblem(Damaged())
    window.show(ProblemReport(damaged, path: nil, hogMode: false))
    #expect(window.fixButton.isHidden)
    window.window.close()
}

/// A fix plays the track again only while the queue's current entry is still the one that
/// failed, so it never interrupts what played since.
@MainActor @Test func aFixPlaysTheTrackAgainOnlyWhileItsStillCurrent() throws {
    let model = NowPlayingModel { _ in nil }
    var state = update(.queueChanged).state
    state.order = [1, 0]
    state.currentIndex = 1
    model.apply(
        PlaybackUpdate(
            state: state, event: .trackFailed(urls[1], entry: 1, PlaybackProblem(NoHogMode()))))
    let shown = try #require(model.problem)
    #expect(shown.entry == 1)
    #expect(try shown.replayPosition(in: state) == 0)

    var movedOn = state
    movedOn.currentIndex = 0
    #expect(throws: ReplayRefusal.movedOn(urls[1])) { try shown.replayPosition(in: movedOn) }
    var replaced = state
    replaced.queue = [urls[0], urls[0]]
    #expect(throws: ReplayRefusal.movedOn(urls[1])) { try shown.replayPosition(in: replaced) }
    var none = shown
    none.entry = nil
    #expect(throws: ReplayRefusal.noTrack) { try none.replayPosition(in: state) }

    // Tracks failing in a row are about the first of them.
    let stopped = inARow([PlaybackProblem(NoHogMode()), PlaybackProblem(NoHogMode())])
    model.apply(update(.failed(stopped.problem)))
    #expect(model.problem?.entry == 0 && model.problem?.track == urls[0])
}
