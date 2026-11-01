import Commands
import Testing

@testable import Scripting

private let names = CommandNames(AppCommands.all())

private func request(_ link: String) -> ScriptRequest? {
    try? scriptRequest(link: link, names: names)
}

private func refusal(_ link: String) -> String? {
    do {
        _ = try scriptRequest(link: link, names: names)
        return nil
    } catch {
        return (error as? ScriptLinkRefusal)?.reason
    }
}

@Test func aLinkRunsAPlaybackOrNavigationCommand() {
    #expect(request("music-player://next") == .run(.nextTrack, argument: nil))
    #expect(request("music-player://next/") == .run(.nextTrack, argument: nil))
    #expect(request("MUSIC-PLAYER://playback.playPause") == .run(.playPause, argument: nil))
    #expect(request("music-player://back") == .run(.back, argument: nil))
    #expect(
        request("music-player://play?q=album:Kind%20of%20Blue")
            == .run(.play, argument: "album:Kind of Blue"))
    // Decoded once: an encoded percent stays one, and a plus stays a plus.
    #expect(request("music-player://play?q=100%2541+x") == .run(.play, argument: "100%41+x"))
    #expect(request("music-player://play?q=") == .run(.play, argument: nil))
}

@Test func everyCommandNotMarkedForLinksIsRefused() {
    for command in AppCommands.all() where !command.runsFromLinks {
        let name = names.name(of: command.id)
        #expect(
            refusal("music-player://\(name)")
                == "\(name) doesn't run from links; use the app or `music-player \(name)`")
    }
}

@Test func anythingButTheExactShapeIsRefused() {
    #expect(
        refusal("music-player://" + String(repeating: "a", count: 2040)) == "it's over 2048 bytes")
    #expect(refusal("https://next") == "it isn't a music-player:// link")
    #expect(refusal("music-player:next") == "it isn't a music-player:// link")
    #expect(refusal("music-player://") == "it names no command, or more than a command")
    #expect(refusal("music-player://next/more") == "it names no command, or more than a command")
    #expect(refusal("music-player://user@next") == "it names no command, or more than a command")
    #expect(refusal("music-player://next:80") == "it names no command, or more than a command")
    #expect(refusal("music-player://next#x") == "it names no command, or more than a command")
    #expect(refusal("music-player://ne%78t") == "it names no command, or more than a command")
    #expect(refusal("music-player://nope") == "nope isn't a command")
    #expect(refusal("music-player://status") == "status isn't a command")
    #expect(refusal("music-player://help") == "help isn't a command")
    #expect(refusal("music-player://play?x=1") == "its query isn't one q=")
    #expect(refusal("music-player://play?q=a&q=b") == "its query isn't one q=")
    #expect(refusal("music-player://play?q=a#b") == "its query isn't one q=")
    #expect(refusal("music-player://next?q=a") == "next takes no argument")
    #expect(refusal("music-player://play?q=%zz") == "its argument isn't percent-encoded properly")
    #expect(refusal("music-player://play?q=a%0Ab") == "the argument holds a control character")
    #expect(refusal("music-player://play?q=a%00b") == "the argument holds a control character")
}
