import Foundation

/// What the drill does on one run, from its arguments, with every folder checked as one the
/// drill may write.
enum DrillCommand {
    case tagFiles(fixtures: URL)
    case run(DrillOperation, home: URL, music: MusicFolders)
    case verify(home: URL)
    case fullDisk(mount: URL, music: MusicFolders)

    private enum Name: String {
        case tagFiles = "tag-files"
        case run, verify
        case fullDisk = "full-disk"

        /// The folders it takes, each once and all of them.
        var flags: [Flag] {
            switch self {
            case .tagFiles: [.fixtures]
            case .run: [.home, .scan, .tags]
            case .verify: [.home]
            case .fullDisk: [.mount, .scan, .tags]
            }
        }
    }

    private enum Flag: String {
        case fixtures = "--fixtures"
        case home = "--home"
        case scan = "--scan"
        case tags = "--tags"
        case mount = "--mount"
    }

    init(_ arguments: [String]) throws {
        guard let text = arguments.first else { throw DrillError("needs a command") }
        guard let name = Name(rawValue: text) else { throw DrillError("\(text) isn't a command") }
        var rest = Array(arguments.dropFirst())
        var operation: DrillOperation?
        if name == .run {
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
        var values: [Flag: URL] = [:]
        while let text = rest.first {
            guard let flag = Flag(rawValue: text), name.flags.contains(flag) else {
                throw DrillError("\(text) isn't an option of \(name.rawValue)")
            }
            guard rest.count > 1, !rest[1].hasPrefix("--") else {
                throw DrillError("\(text) needs a folder")
            }
            guard values[flag] == nil else { throw DrillError("\(text) is given twice") }
            values[flag] = try drillFolder(rest[1])
            rest.removeFirst(2)
        }
        if let missing = name.flags.first(where: { values[$0] == nil }) {
            throw DrillError("\(name.rawValue) needs \(missing.rawValue)")
        }
        let music = values[.scan].map { MusicFolders(scan: $0, tags: values[.tags]!) }
        switch name {
        case .tagFiles: self = .tagFiles(fixtures: values[.fixtures]!)
        case .run: self = .run(operation!, home: values[.home]!, music: music!)
        case .verify: self = .verify(home: values[.home]!)
        case .fullDisk: self = .fullDisk(mount: values[.mount]!, music: music!)
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
