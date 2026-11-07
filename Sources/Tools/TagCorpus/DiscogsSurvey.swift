import Foundation
import Library
import Metadata

/// The Discogs survey's folder: `.build/discogs-survey` under the current directory, the only
/// place the survey writes (ADR 0128).
func surveyFolder() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(".build/discogs-survey", isDirectory: true)
}

/// The survey's lines, one per file, in its folder: the read-once cache the tuning reads too.
let surveyLinesName = "files.jsonl"
/// The name of the survey's report and the tuning's, each in its own folder.
let reportName = "report.txt"

/// Reads every audio file under `folders`, read only, appending a line per file to
/// `files.jsonl` in `output`, then writes `report.txt` there from every line. A file already in
/// `files.jsonl` isn't read again, so a stopped run resumes where it was. Progress goes to
/// standard error. Returns how many files couldn't be read.
func discogsSurvey(_ folders: [URL], output: URL) throws -> Int {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let lines = output.appendingPathComponent(surveyLinesName, isDirectory: false)
    let report = output.appendingPathComponent(reportName, isDirectory: false)
    for file in [lines, report] { try requireCorpusWrite(file.path, roots: [output]) }

    var records = try loadRecords(lines)
    let done = Set(records.map(\.path))
    progress("listing \(folders.map(\.path).joined(separator: ", "))")
    var files: [String] = []
    for folder in folders { files += try surveyFiles(in: folder) }
    let remaining = files.filter { !done.contains($0) }
    progress("\(files.count) files, \(remaining.count) left to read")

    if !FileManager.default.fileExists(atPath: lines.path) {
        guard FileManager.default.createFile(atPath: lines.path, contents: nil) else {
            throw CorpusError("can't create \(lines.path)")
        }
    }
    let handle = try FileHandle(forWritingTo: lines)
    defer { try? handle.close() }
    try handle.seekToEnd()
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let started = Date()
    let chunk = 64
    for start in stride(from: 0, to: remaining.count, by: chunk) {
        let batch = Array(remaining[start..<min(start + chunk, remaining.count)])
        let read = readConcurrently(batch)
        var data = Data()
        for record in read {
            data += try encoder.encode(record)
            data.append(UInt8(ascii: "\n"))
        }
        try handle.write(contentsOf: data)
        records += read
        let count = start + batch.count
        let rate = Double(count) / max(Date().timeIntervalSince(started), 1)
        progress(
            String(
                format: "read %d of %d, %.0f files/s, about %.0f min left", count,
                remaining.count, rate, Double(remaining.count - count) / rate / 60))
    }
    try requireCorpusWrite(report.path, roots: [output])
    try Data(surveyReport(records, folders: folders).utf8).write(to: report)
    progress("wrote \(report.path)")
    return records.filter { $0.failure != nil }.count
}

/// The audio files under `folder` by the scanner's extensions, sorted, skipping hidden files.
/// Throws when `folder` isn't a folder or a folder in it can't be listed, so a survey never
/// reports on part of a library as if it were all of it.
func surveyFiles(in folder: URL) throws -> [String] {
    var isFolder: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder),
        isFolder.boolValue
    else { throw CorpusError("\(folder.path) isn't a folder") }
    var unlisted: [String] = []
    guard
        let walk = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [], options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                unlisted.append("\(url.path): \(error.localizedDescription)")
                return true
            })
    else { throw CorpusError("can't list \(folder.path)") }
    var files: [String] = []
    for case let url as URL in walk
    where audioFileExtensions.contains(url.pathExtension.lowercased()) {
        files.append(url.path)
    }
    guard unlisted.isEmpty else {
        throw CorpusError(
            "folders under \(folder.path) couldn't be listed: \(unlisted.joined(separator: "; "))")
    }
    return files.sorted()
}

/// The lines of an earlier run. A last line a stop cut short is dropped, and the file truncated
/// before it, so the next line starts on a line of its own.
func loadRecords(_ lines: URL) throws -> [SurveyRecord] {
    guard FileManager.default.fileExists(atPath: lines.path) else { return [] }
    var data = try Data(contentsOf: lines)
    if let last = data.last, last != UInt8(ascii: "\n") {
        let end = data.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? 0
        data = data.prefix(end)
        try requireCorpusWrite(lines.path, roots: [lines.deletingLastPathComponent()])
        let handle = try FileHandle(forWritingTo: lines)
        try handle.truncate(atOffset: UInt64(end))
        try handle.close()
    }
    let decoder = JSONDecoder()
    return try data.split(separator: UInt8(ascii: "\n")).map {
        try decoder.decode(SurveyRecord.self, from: Data($0))
    }
}

/// Each file of `paths` read by `surveyRecord`, `filesReadAtOnce` at a time, in their order.
private func readConcurrently(_ paths: [String]) -> [SurveyRecord] {
    let results = SurveyResults(count: paths.count)
    DispatchQueue.concurrentPerform(iterations: paths.count) { index in
        results.set(index, surveyRecord(paths[index]))
    }
    return results.records
}

/// Reads `path`'s tags through a read-only `FileSource`, opened once.
func surveyRecord(_ path: String) -> SurveyRecord {
    do throws(ParseFailure) {
        let reader = ByteReader(try FileSource(path: path))
        let format = try FileFormat(reader)
        return SurveyRecord(
            path: path, format: format.rawValue, metadata: try parse(reader).metadata)
    } catch {
        return SurveyRecord(path: path, failure: error.error(path: path).description)
    }
}

private func progress(_ line: String) {
    FileHandle.standardError.write(Data("\(line)\n".utf8))
}

/// The records of one batch, set from the threads that read them.
private final class SurveyResults: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [SurveyRecord?]

    init(count: Int) { slots = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ record: SurveyRecord) {
        lock.lock()
        slots[index] = record
        lock.unlock()
    }

    var records: [SurveyRecord] {
        lock.lock()
        defer { lock.unlock() }
        return slots.map { $0! }
    }
}
