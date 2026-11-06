import AppKit
import Commands
import DisplayText
import LocalSocket
import Scripting
import Settings

// music-player <command> [<argument>] [--home <folder>]
// Runs a registry command in the app over its socket, starting the app first when nothing
// answers. `music-player help` lists the commands; ADR 0036 has the design.

/// How long a started app has to open its socket: its launch, then the first rows of the
/// library, on the 2015 MacBook Pro with room to spare.
let launchWaitSeconds = 20.0
let retrySeconds = 0.1

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data("error: \(terminalSafe(text))\n".utf8))
    exit(1)
}

let names = CommandNames(AppCommands.all())
let invocation: ScriptInvocation
do {
    invocation = try parseScriptArguments(Array(CommandLine.arguments.dropFirst()), names: names)
} catch {
    fail("\(error)")
}
guard case .request(let request) = invocation.action else {
    print(scriptHelp(names))
    exit(0)
}

let paths: AppPaths
do {
    paths =
        try invocation.home.map { AppPaths(home: URL(fileURLWithPath: $0, isDirectory: true)) }
        ?? .standard()
} catch {
    fail("couldn't find the app's data folder: \(error)")
}
let socket = scriptSocketPath(dataDirectory: paths.dataDirectory)

/// The reply, or nil when nothing answers on the socket yet. While a started app comes up,
/// `starting` also counts a connection it closes unanswered as not ready.
func exchange(timeoutSeconds: Double = ScriptLimits.replySeconds, starting: Bool = false)
    -> ScriptReply?
{
    do {
        return try sendScriptRequest(request, path: socket, timeoutSeconds: timeoutSeconds)
    } catch LocalSocketError.notListening {
        return nil
    } catch LocalSocketError.closed where starting {
        return nil
    } catch {
        fail("\(error)")
    }
}

/// The app this tool is inside: `Music Player.app/Contents/MacOS/music-player`.
func enclosingApp() -> URL? {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let app = executable.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    return app.pathExtension == "app" ? app : nil
}

func launchAndWait() async -> ScriptReply {
    guard let app = enclosingApp() else {
        fail(
            "the app isn't answering at \(socket), and this \(toolName) isn't inside it to start it"
        )
    }
    // One deadline for the start and every try after it.
    let deadline = Date().addingTimeInterval(launchWaitSeconds)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = invocation.launchArguments
    do {
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    } catch {
        fail("couldn't start \(app.path): \(error)")
    }
    while case let left = deadline.timeIntervalSinceNow, left > 0 {
        if let reply = exchange(timeoutSeconds: left, starting: true) { return reply }
        try? await Task.sleep(nanoseconds: UInt64(retrySeconds * 1e9))
    }
    fail("the app didn't answer at \(socket) within \(Int(launchWaitSeconds)) s of starting")
}

let reply: ScriptReply
if let answered = exchange() {
    reply = answered
} else {
    reply = await launchAndWait()
}
switch reply {
case .done(let message):
    // Line by line, so a reply of several lines, such as stats, keeps them.
    if let message {
        print(
            message.split(separator: "\n", omittingEmptySubsequences: false)
                .map { terminalSafe(String($0)) }.joined(separator: "\n"))
    }
case .failed(let message):
    fail(message)
case .status(let status):
    if invocation.json {
        do {
            print(try status.json())
        } catch {
            fail("couldn't write the status as JSON: \(error)")
        }
    } else {
        print(status.text)
    }
}
