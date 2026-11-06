import Foundation
import Metadata
import Testing

@testable import Fixtures
@testable import Playback

private struct StandIn: Error, CustomStringConvertible {
    var description: String { "StandIn(code: 7)" }
}

@Test func everyPlaybackErrorHasAPlainMessage() {
    let errors: [PlaybackError] = [
        .noVolume,
        .failedInARow(
            [URL(fileURLWithPath: "/m/a.dsf", isDirectory: false)].map {
                FailedTrack(
                    url: $0, entry: 0,
                    problem: PlaybackProblem(MetadataError(unreadable: $0.path, detail: "gone")))
            }),
        .startedTrackMissing(URL(fileURLWithPath: "/m/a.flac", isDirectory: false)),
    ]
    for error in errors {
        #expect(readsAsPlainText(error.userMessage), "\(error.userMessage)")
    }
}

/// The message is a playback failure's own and the detail its full text; another error's
/// description is both.
@Test func aProblemTakesTheMessageAndKeepsTheFullText() {
    let problem = PlaybackProblem(MetadataError(unreadable: "/m/a.dsf", detail: "no such file"))
    #expect(problem.message == "the file can't be read")
    #expect(problem.detail == "/m/a.dsf: no such file")
    let other = PlaybackProblem(StandIn())
    #expect(other.message == "StandIn(code: 7)" && other.detail == "StandIn(code: 7)")
}
