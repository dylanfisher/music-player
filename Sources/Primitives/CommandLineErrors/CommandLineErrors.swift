import Foundation

/// Writes `error: <message>` to standard error and exits with `exitCode`: how a tool stops on a
/// bad argument or a failure it can't go on from.
public func fail(_ message: String, exitCode: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(exitCode)
}

/// What a command line says about a flag it can't take, the same in every program that has
/// flags: the app, the music-player tool and the development tools.
public enum FlagMessage {
    /// The value of a flag that takes a folder, as `missingValue` names it.
    public static let folder = "a folder"

    public static func unknown(_ flag: String) -> String { "\(flag) isn't an option" }

    /// `flag` without its value, `what`: "a folder", "a number".
    public static func missingValue(_ flag: String, _ what: String) -> String {
        "\(flag) needs \(what)"
    }

    public static func givenTwice(_ flag: String) -> String { "\(flag) is given twice" }

    public static func onlyWith(_ flag: String, _ other: String) -> String {
        "\(flag) only goes with \(other)"
    }

    public static func notACommand(_ word: String) -> String { "\(word) isn't a command" }
}
