import Foundation

/// Where a run is, on standard output, for scripts/kill-test to tell where each kill landed:
/// a line before each write starts and one after it ends. Each goes straight to the file
/// descriptor, so a line written before the kill is there after it.
enum WriteMark: String, CaseIterable {
    case begin = "write begins"
    case end = "write ends"

    func write() { FileHandle.standardOutput.write(Data((rawValue + "\n").utf8)) }
}

/// Runs `write` between a begin and an end mark.
func marked<T>(_ write: () throws -> T) rethrows -> T {
    WriteMark.begin.write()
    defer { WriteMark.end.write() }
    return try write()
}
