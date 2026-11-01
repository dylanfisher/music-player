import Foundation

/// What the drill does on one run, from its arguments, with every folder checked as one the
/// drill may write.
enum DrillCommand {
    case tagFiles(fixtures: URL)
    case run(DrillOperation, home: URL, music: MusicFolders)
    case verify(home: URL)
    case fullDisk(mount: URL, music: MusicFolders)

    init(_ arguments: [String]) throws {
        guard let name = arguments.first else { throw DrillError("needs a command") }
        var rest = Array(arguments.dropFirst())
        var operation: DrillOperation?
        if name == "run" {
            guard let text = rest.first, !text.hasPrefix("--") else {
                throw DrillError(
                    "run needs an operation: "
                        + DrillOperation.allCases.map(\.rawValue).joined(separator: ", "))
            }
            guard let parsed = DrillOperation(rawValue: text) else {
                throw DrillError("\(text) isn't an operation")
            }
            operation = parsed
            rest.removeFirst()
        }
        let allowed: [String] =
            switch name {
            case "tag-files": ["--fixtures"]
            case "run": ["--home", "--scan", "--tags"]
            case "verify": ["--home"]
            case "full-disk": ["--mount", "--scan", "--tags"]
            default: throw DrillError("\(name) isn't a command")
            }
        var values: [String: URL] = [:]
        while let flag = rest.first {
            guard allowed.contains(flag) else { throw DrillError("\(flag) isn't an option here") }
            guard rest.count > 1, !rest[1].hasPrefix("--") else {
                throw DrillError("\(flag) needs a folder")
            }
            guard values[flag] == nil else { throw DrillError("\(flag) is given twice") }
            values[flag] = try drillFolder(rest[1])
            rest.removeFirst(2)
        }
        if let missing = allowed.first(where: { values[$0] == nil }) {
            throw DrillError("\(name) needs \(missing)")
        }
        let music = values["--scan"].map { MusicFolders(scan: $0, tags: values["--tags"]!) }
        switch name {
        case "tag-files": self = .tagFiles(fixtures: values["--fixtures"]!)
        case "run": self = .run(operation!, home: values["--home"]!, music: music!)
        case "verify": self = .verify(home: values["--home"]!)
        default: self = .fullDisk(mount: values["--mount"]!, music: music!)
        }
    }
}

enum DrillOperation: String, CaseIterable {
    case scan
    case tagWrite = "tag-write"
    case playlistEdit = "playlist-edit"
    case stateSave = "state-save"
}

/// The music a drill uses: the fixture library it scans and the clones the tag writer edits.
struct MusicFolders {
    var scan: URL
    var tags: URL
}

struct DrillError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
