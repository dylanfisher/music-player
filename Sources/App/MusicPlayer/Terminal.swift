import Foundation

/// The terminal settings from before `enterKeyMode`, global so the `atexit` handler can reach them.
nonisolated(unsafe) private var savedTerminal: termios?

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
    return true
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
    var escape: [UInt8] = []
    var byte: UInt8 = 0
    while read(STDIN_FILENO, &byte, 1) == 1 {
        // Arrow keys arrive as ESC [ C (right) and ESC [ D (left).
        if byte == 0x1B || !escape.isEmpty {
            escape.append(byte)
            guard escape.count == 3 else { continue }
            defer { escape = [] }
            switch (escape[1], escape[2]) {
            case (UInt8(ascii: "["), UInt8(ascii: "C")): pressed(.forward)
            case (UInt8(ascii: "["), UInt8(ascii: "D")): pressed(.back)
            default: continue
            }
            continue
        }
        switch byte {
        case UInt8(ascii: " "): pressed(.space)
        case UInt8(ascii: "n"): pressed(.next)
        case UInt8(ascii: "p"): pressed(.previous)
        case UInt8(ascii: "q"): pressed(.quit)
        case UInt8(ascii: "r"): pressed(.repeatMode)
        case UInt8(ascii: "s"): pressed(.shuffle)
        case UInt8(ascii: "-"): pressed(.volumeDown)
        case UInt8(ascii: "+"), UInt8(ascii: "="): pressed(.volumeUp)
        default: continue
        }
    }
}
