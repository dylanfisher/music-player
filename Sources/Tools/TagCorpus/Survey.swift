import Foundation
import Metadata
import TagWriter

/// Lists every file's tag layout under `folder`, then what the files have in common and what
/// stands out, for ADR 0020.
func survey(_ folder: URL) throws -> Int {
    var containers: [String: Int] = [:]
    var notes: [String: Int] = [:]
    var fieldPaths: [String: Int] = [:]
    var padding: [String: [Int]] = [:]
    var failures: [String] = []
    var warnings: [String] = []
    for file in try audioFiles(in: folder) {
        let relative = String(file.path.dropFirst(folder.path.count + 1))
        do {
            let layout = try readTagLayout(at: file)
            let parsed = try readMetadata(at: file)
            containers[layout.container.rawValue, default: 0] += 1
            for note in layout.notes {
                notes["\(layout.container.rawValue): \(note)", default: 0] += 1
            }
            padding[layout.container.rawValue, default: []].append(layout.paddingBytes)
            print(
                "\(relative)  [\(layout.container.rawValue)] \(layout.notes.joined(separator: "; "))"
            )
            for block in layout.blocks {
                print(
                    "  \(block.kind.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0))"
                        + " \(block.range.lowerBound)..<\(block.range.upperBound) (\(block.range.count))"
                        + "  \(block.path)")
                if block.kind == .field || block.kind == .art {
                    fieldPaths["\(layout.container.rawValue) \(block.path)", default: 0] += 1
                }
            }
            print(
                "  payload \(layout.payload.map { "\($0.lowerBound)..<\($0.upperBound)" })"
                    + ", padding \(layout.paddingBytes), art \(parsed.metadata.art.map { "\($0.mimeType) \($0.byteCount) B" } ?? "none")"
            )
            for warning in parsed.warnings { warnings.append("\(relative): \(warning)") }
        } catch {
            failures.append("\(relative): \(error)")
        }
    }
    print("\n== Summary")
    for (name, count) in containers.sorted(by: { $0.key < $1.key }) { print("\(count) \(name)") }
    print("\n== Notes")
    for (note, count) in notes.sorted(by: { $0.key < $1.key }) { print("\(count) \(note)") }
    print("\n== Padding bytes (min, max)")
    for (name, values) in padding.sorted(by: { $0.key < $1.key }) {
        print(
            "\(name): \(values.min() ?? 0)–\(values.max() ?? 0), \(values.filter { $0 == 0 }.count) with none"
        )
    }
    print("\n== Fields and art (files)")
    for (path, count) in fieldPaths.sorted(by: { $0.key < $1.key }) { print("\(count) \(path)") }
    print("\n== Reader warnings (\(warnings.count))")
    for warning in warnings { print(warning) }
    print("\n== Unreadable layouts (\(failures.count))")
    for failure in failures { print(failure) }
    return failures.count
}

/// The audio files under `folder`, by the scanner's extensions, sorted by path.
func audioFiles(in folder: URL) throws -> [URL] {
    guard
        let walk = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
    else { throw CorpusError("can't list \(folder.path)") }
    var files: [URL] = []
    for case let url as URL in walk
    where corpusAudioExtensions.contains(url.pathExtension.lowercased()) {
        files.append(url)
    }
    return files.sorted { $0.path < $1.path }
}

/// The extensions the writer handles.
let corpusAudioExtensions: Set<String> = ["flac", "m4a", "mp4", "mp3", "wav", "aif", "aiff"]

struct CorpusError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
