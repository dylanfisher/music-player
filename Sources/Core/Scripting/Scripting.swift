import Foundation

/// The command line's name, as the bundle installs it and help prints it.
public let toolName = "music-player"
/// The scheme of the links that run commands. The same word as the tool, so a link and a
/// command read alike: `music-player://next`, `music-player next`.
public let urlScheme = toolName

/// The socket the app answers on, in a folder of its own inside the data folder, so `--home`
/// moves it with everything else.
public func scriptSocketPath(dataDirectory: URL) -> String {
    dataDirectory.appendingPathComponent("scripting").appendingPathComponent("socket").path
}

/// Caps on what crosses the socket. A request is a command ID and an argument; a reply is at
/// most a status with one track's tags.
public enum ScriptLimits {
    static let requestBytes = 4096
    static let replyBytes = 65536
    /// How long the app waits for a request to arrive whole, and for its reply to be read.
    static let socketTimeoutSeconds = 2.0
    /// How long the tool waits for a reply, which may follow a library query.
    public static let replySeconds = 10.0
    static let argumentBytes = 1024
    static let urlBytes = 2048
}

/// What the parser, the link check and the router say alike.
enum ScriptMessage {
    static func notACommand(_ name: String) -> String { "\(name) isn't a command" }
    static func takesNoArgument(_ name: String) -> String { "\(name) takes no argument" }
}
