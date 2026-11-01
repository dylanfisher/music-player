import Foundation
import LocalSocket
import Playback
import Testing

@testable import Scripting

func localSocketExchangeForTests(path: String, _ request: Data) throws -> Data {
    try localSocketExchange(path: path, request: request, replyCap: 65536, timeoutSeconds: 5)
}

private func json(_ status: ScriptStatus) throws -> String { try status.json() }

private var playing: PlaybackState {
    var state = PlaybackState()
    state.status = .playing
    state.queue = [URL(fileURLWithPath: "/m/a.flac"), URL(fileURLWithPath: "/m/b.flac")]
    state.order = [1, 0]
    state.currentIndex = 0
    state.shuffle = true
    state.repeatMode = .all
    return state
}

@Test func theStatusShapeIsFixedWithNullsForMissingValues() throws {
    let stopped = ScriptStatus(PlaybackState(), positionSeconds: 3, track: nil)
    #expect(
        try json(stopped)
            == #"{"positionSeconds":null,"queueLength":0,"queuePosition":null,"repeat":"off","shuffle":false,"state":"stopped","track":null}"#
    )
    let track = ScriptStatus.Track(
        path: "/m/a.flac", title: "So What", artist: "Miles Davis", album: "Kind of Blue",
        albumArtist: nil, durationSeconds: 562.5)
    let status = ScriptStatus(playing, positionSeconds: 65.2, track: track)
    #expect(
        try json(status)
            == #"{"positionSeconds":65.2,"queueLength":2,"queuePosition":2,"repeat":"all","shuffle":true,"state":"playing","track":{"album":"Kind of Blue","albumArtist":null,"artist":"Miles Davis","durationSeconds":562.5,"path":"/m/a.flac","title":"So What"}}"#
    )
    #expect(try JSONDecoder().decode(ScriptStatus.self, from: Data(json(status).utf8)) == status)
    #expect(
        status.text
            == "Playing\nSo What\nby Miles Davis\non Kind of Blue\n1:05 of 9:22, track 2 of 2, shuffle on, repeat all"
    )
}

@Test func statusTextIsEscapedForTheTerminal() {
    let track = ScriptStatus.Track(
        path: "/m/x.flac", title: "a\u{1B}[2Jb", artist: nil, album: nil, albumArtist: nil,
        durationSeconds: nil)
    #expect(ScriptStatus(playing, positionSeconds: nil, track: track).text.contains("a\\u{1B}[2Jb"))
}

@Test func anUnknownExtraOrMissingKeyAtAnyLevelIsRefused() throws {
    let status = try json(
        ScriptStatus(
            playing, positionSeconds: 1,
            track: ScriptStatus.Track(
                path: "/p", title: nil, artist: nil, album: nil, albumArtist: nil,
                durationSeconds: nil)))
    let bad = [
        status.replacingOccurrences(of: #""shuffle":true"#, with: #""shuffle":true,"x":1"#),
        status.replacingOccurrences(of: #""path":"/p""#, with: #""path":"/p","x":1"#),
        status.replacingOccurrences(of: #""queuePosition":2,"#, with: ""),
        status.replacingOccurrences(of: #","title":null"#, with: ""),
        status.replacingOccurrences(of: #""repeat":"all""#, with: #""repeat":"twice""#),
    ]
    for text in bad {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ScriptStatus.self, from: Data(text.utf8))
        }
    }
    for text in [
        #"{"kind":"status","command":"x"}"#, #"{"kind":"run"}"#,
        #"{"kind":"run","command":"a","x":1}"#,
        #"{"kind":"done","status":{}}"#,
    ] {
        #expect(throws: DecodingError.self) {
            if text.contains("done") {
                _ = try JSONDecoder().decode(ScriptReply.self, from: Data(text.utf8))
            } else {
                _ = try JSONDecoder().decode(ScriptRequest.self, from: Data(text.utf8))
            }
        }
    }
}
