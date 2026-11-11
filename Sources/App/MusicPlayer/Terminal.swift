import Foundation

/// The terminal settings from before `enterKeyMode`, global so the `atexit` handler can reach them.
/// Set once, by `enterKeyMode`, before the signal handlers that read it start.
nonisolated(unsafe) private var savedTerminal: termios?
/// The settings `enterKeyMode` set, to put back after the shell resumes the process.
/// Set once, by `enterKeyMode`, before the signal handlers that read it start.
nonisolated(unsafe) private var keyTerminal: termios?

/// Turns off line buffering and echo, so each key press arrives as it happens, and puts the
/// terminal back at any exit, including a second Ctrl-C. Ctrl-C still sends SIGINT. Returns false
/// when standard input isn't a terminal.
func enterKeyMode() throws -> Bool {
    guard isatty(STDIN_FILENO) == 1 else { return false }
    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw TerminalError(call: "tcgetattr") }
    savedTerminal = original
    atexit { restoreTerminal() }
    var keys = original
    keys.c_lflag &= ~tcflag_t(ICANON | ECHO)
    withUnsafeMutableBytes(of: &keys.c_cc) { characters in
        characters[Int(VMIN)] = 1
        characters[Int(VTIME)] = 0
    }
    guard tcsetattr(STDIN_FILENO, TCSANOW, &keys) == 0 else {
        throw TerminalError(call: "tcsetattr")
    }
    keyTerminal = keys
    return true
}

/// Puts key mode back after Ctrl-Z and `fg`, since the shell restores its own settings meanwhile.
func resumeKeyMode() {
    guard var keys = keyTerminal else { return }
    if tcsetattr(STDIN_FILENO, TCSANOW, &keys) != 0 {
        FileHandle.standardError.write(Data("warning: couldn't turn key mode back on\n".utf8))
    }
}

func restoreTerminal() {
    guard var saved = savedTerminal else { return }
    // On the way out, a failure leaves nothing to do but say so.
    if tcsetattr(STDIN_FILENO, TCSANOW, &saved) != 0 {
        FileHandle.standardError.write(Data("warning: couldn't restore the terminal\n".utf8))
    }
}

struct TerminalError: Error, CustomStringConvertible {
    var call: String
    var description: String { "\(call) failed: \(String(cString: strerror(errno)))" }
}

enum Key {
    case space, next, previous, forward, back, quit, repeatMode, shuffle, volumeDown, volumeUp
}

/// Blocks reading standard input and calls `pressed` for each key it knows, until input ends.
func readKeys(_ pressed: (Key) -> Void) {
    var parser = KeyParser()
    var byte: UInt8 = 0
    while read(STDIN_FILENO, &byte, 1) == 1 {
        if let key = parser.key(after: byte) { pressed(key) }
    }
}

/// Turns terminal input, one byte at a time, into keys.
struct KeyParser {
    /// ESC, then `[` or `O`, while an arrow key's sequence is arriving.
    private var sequence: [UInt8] = []

    /// The key `byte` completes, if any. Arrow keys arrive as ESC [ C and ESC [ D, or with `O` in
    /// place of `[` in application mode.
    mutating func key(after byte: UInt8) -> Key? {
        switch sequence.count {
        case 1:
            if byte == UInt8(ascii: "[") || byte == UInt8(ascii: "O") {
                sequence.append(byte)
                return nil
            }
            // Not a sequence: the escape was a key of its own, and this byte is another.
            sequence = []
        case 2:
            sequence = []
            switch byte {
            case UInt8(ascii: "C"): return .forward
            case UInt8(ascii: "D"): return .back
            default: return nil
            }
        default: break
        }
        switch byte {
        case 0x1B:
            sequence = [byte]
            return nil
        case UInt8(ascii: " "): return .space
        case UInt8(ascii: "n"): return .next
        case UInt8(ascii: "p"): return .previous
        case UInt8(ascii: "q"): return .quit
        case UInt8(ascii: "r"): return .repeatMode
        case UInt8(ascii: "s"): return .shuffle
        case UInt8(ascii: "-"): return .volumeDown
        case UInt8(ascii: "+"), UInt8(ascii: "="): return .volumeUp
        default: return nil
        }
    }
}
