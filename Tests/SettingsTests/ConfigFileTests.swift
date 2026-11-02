import Foundation
import KeyChord
import Testing

@testable import Settings

private enum Shade: String, SettingChoice {
    case auto, light, dark

    var title: String { rawValue.capitalized }
}

private struct Schema: SettingsSchema {
    let flag = Setting("a.flag", title: "Flag", default: false, "A bool.")
    let count = Setting("a.count", title: "Count", default: 5, range: 1...10, "An integer.")
    let shade = Setting("shade", title: "Shade", default: Shade.auto, "A choice.")
    let folders = Setting<[WatchedFolder]>("folders", title: "Folders", default: [], "A list.")
}

private let settings = Schema().settings
/// Refuses ⌘Q, and any command but "test.open".
private let check: ShortcutCheck = { id, _, slot in
    if id != "test.open" { return "no command has the ID \"\(id)\"" }
    if slot == .chord(KeyChord("q", .command)) { return "cmd+q is Quit's" }
    return nil
}

private func parsed(_ text: String) throws(ConfigErrorList) -> ConfigContents {
    try ConfigFile.parse(ConfigText(text), settings: settings, check: check)
}

private func problems(_ text: String) -> [String] {
    do {
        _ = try parsed(text)
        Issue.record("accepted \(text)")
        return []
    } catch {
        return error.problems.map(\.description)
    }
}

@Test func commentsTrailingCommasAndAByteOrderMarkAreAllowed() throws {
    let text =
        "\u{FEFF}{\n  // a line comment with \"quotes\" and /* markers\n  \"a.flag\": true, /* a block */\n"
        + "  \"a.count\": 7, // after\n  \"folders\": [],\n}\n"
    let contents = try parsed(text)
    #expect(contents.values["a.flag"] as? Bool == true)
    #expect(contents.values["a.count"] as? Int == 7)
    #expect(
        try parsed(
            #"{"a.flag": "//not a comment", }"#.replacingOccurrences(
                of: "\"//not a comment\"", with: "true")
        ).values.count == 1)
}

@Test func eachProblemIsOnItsLine() {
    #expect(
        problems("{\n  \"a.flag\": true,\n  \"a.flg\": true\n}") == [
            #"line 3: unknown setting "a.flg""#
        ])
    #expect(problems("{\n\n  \"a.count\": 11\n}") == [#"line 3: "a.count": 11 is outside 1...10"#])
    #expect(
        problems("{\n  \"a.flag\": true,\n  \"a.flag\": false\n}") == [
            #"line 3: "a.flag" is set twice"#
        ])
    #expect(problems("{\n  /* never closed\n}") == ["line 2: a /* comment is never closed"])
    #expect(problems("{,}").count == 1)
    #expect(
        problems("{\n  \"a.flag\": tru\n}").first?.hasPrefix("line 2: isn't valid JSON") == true)
    #expect(problems("  \n// nothing\n") == ["the file is empty"])
    #expect(problems("[1]") == ["must be a JSON object of settings"])
}

/// Inputs the fuzzer found that crashed the scan (ADR 0027), each a problem now.
@Test(arguments: ["double-comma-after-a-comment", "double-comma-before-a-comment"])
func fuzzedFilesAreProblemsNotCrashes(_ name: String) throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Crashes/\(name).json")
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(problems(text).first?.contains("isn't valid JSON") == true, "\(problems(text))")
    #expect(problems("{\"a.flag\": true,,}").count == 1)
    #expect(problems("[1,,]").count == 1)
}

/// The fuzzer's file of mangled keys took over 10 s to report, counting each problem's line from
/// the start of the file. Lines come from an index of the line breaks now.
@Test func aFileWithThousandsOfProblemsKeepsEachOnItsLine() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Crashes/many-problems.json")
    #expect(!problems(String(decoding: try Data(contentsOf: url), as: UTF8.self)).isEmpty)
    let lines = (1...20_000).map { "  \"unknown\($0)\": 1," }
    let text = ConfigText("{\n" + lines.joined(separator: "\n") + "\n}\n")
    var offset = 2
    for (index, line) in lines.enumerated() {
        if index % 997 == 0 {
            #expect(text.line(at: offset) == index + 2)
            #expect(text.line(at: offset + line.utf8.count) == index + 2)
        }
        offset += line.utf8.count + 1
    }
    #expect(text.line(at: 0) == 1)
    #expect(text.line(at: text.bytes.count) == 20_003)
    let found = problems(text.string)
    #expect(found.count == 20_000)
    #expect(found.last == #"line 20001: unknown setting "unknown20000""#)
}

@Test func duplicatesAreFoundInsideNestedObjects() {
    let text = """
        {
          "shortcuts": {
            "test.open": {"primary": "cmd+o", "primary": "cmd+p"}
          }
        }
        """
    #expect(problems(text) == [#"line 3: "primary" is set twice"#])
}

@Test func shortcutsAreCheckedSlotBySlot() throws {
    let good = try parsed(
        #"{"shortcuts": {"test.open": {"primary": "cmd+shift+o", "alternate": ""}}}"#)
    #expect(
        good.shortcuts["test.open"]
            == ShortcutOverride(
                primary: .chord(KeyChord("o", [.command, .shift])), alternate: .removed))
    #expect(
        problems(
            """
            {"shortcuts": {
              "test.open": {"primary": "shift+cmd+o", "third": "f5"},
              "test.nope": {"primary": "f5"},
              "test.open2": "f5"
            }}
            """
        ).count == 4)
    #expect(
        problems(#"{"shortcuts": {"test.open": {"primary": "cmd+q"}}}"#) == [
            "line 1: shortcuts.test.open.primary: cmd+q is Quit's"
        ])
}

@Test func aNewFileListsEveryDefaultWithItsComment() throws {
    let text = ConfigFile.defaultText(settings: settings)
    #expect(
        text.contains("  // An integer.\n  // Takes an integer from 1 to 10.\n  \"a.count\": 5,"))
    #expect(text.contains(#"// Takes one of "auto", "light", "dark"."#))
    #expect(text.hasSuffix("  \"shortcuts\": {}\n}\n"))
    let contents = try parsed(text)
    #expect(contents.values.count == settings.count)
    #expect(contents.shortcuts.isEmpty)
}

@Test func patchesKeepEverythingElse() throws {
    let text = "{\n  // keep me\n  \"a.flag\": false, // and me\n  \"a.count\": 5\n}"
    let flag = settings.first { $0.key == "a.flag" }!
    let shade = settings.first { $0.key == "shade" }!
    var patched = try ConfigFile.patch(ConfigText(text), setting: flag, to: true)
    #expect(patched.string == "{\n  // keep me\n  \"a.flag\": true, // and me\n  \"a.count\": 5\n}")
    patched = try ConfigFile.patch(patched, setting: shade, to: Shade.dark)
    #expect(
        patched.string
            == "{\n  // keep me\n  \"a.flag\": true, // and me\n  \"a.count\": 5,\n  // A choice.\n"
            + "  // Takes one of \"auto\", \"light\", \"dark\".\n  \"shade\": \"dark\"\n}")
    #expect(try parsed(patched.string).values["shade"] as? Shade == .dark)
}

@Test func patchesFollowTheFilesShape() throws {
    let flag = settings.first { $0.key == "a.flag" }!
    #expect(
        try ConfigFile.patch(ConfigText(#"{"a.count": 5}"#), setting: flag, to: true).string
            == #"{"a.count": 5, "a.flag": true}"#)
    #expect(
        try ConfigFile.patch(ConfigText("{}\n"), setting: flag, to: true).string
            == "{\n  // A bool.\n  // Takes true or false.\n  \"a.flag\": true\n}\n")
    // The last member shares its line with the close.
    let closing = try ConfigFile.patch(ConfigText("{\n  \"a.count\": 5 }"), setting: flag, to: true)
    #expect(
        closing.string
            == "{\n  \"a.count\": 5,\n  // A bool.\n  // Takes true or false.\n  \"a.flag\": true }"
    )
    #expect(try parsed(closing.string).values["a.flag"] as? Bool == true)
    let crlf = "{\r\n  \"a.count\": 5,\r\n}\r\n"
    #expect(
        try ConfigFile.patch(ConfigText(crlf), setting: flag, to: true).string
            == "{\r\n  \"a.count\": 5,\r\n  // A bool.\r\n  // Takes true or false.\r\n  \"a.flag\": true,\r\n}\r\n"
    )
    let folders = settings.first { $0.key == "folders" }!
    let list = try ConfigFile.patch(
        ConfigText("{\n  \"folders\": []\n}"), setting: folders,
        to: [WatchedFolder(path: "/M", kind: .local)])
    #expect(
        try parsed(list.string).values["folders"] as? [WatchedFolder] == [
            WatchedFolder(path: "/M", kind: .local)
        ])
    #expect(list.string.contains("\n    {\n      \"exclude\""))
}

@Test func shortcutPatchesAddChangeAndRemoveCommands() throws {
    let open = ShortcutOverride(alternate: .chord(KeyChord("o", [.command, .shift])))
    var text = try ConfigFile.patch(
        ConfigText("{\n  \"a.flag\": true\n}"), shortcut: "test.open", to: open)
    #expect(try parsed(text.string).shortcuts["test.open"] == open)
    #expect(text.string.contains(#""test.open": {"alternate": "cmd+shift+o"}"#))
    text = try ConfigFile.patch(
        text, shortcut: "test.open", to: ShortcutOverride(primary: .removed))
    #expect(text.string.contains(#""test.open": {"primary": ""}"#))
    text = try ConfigFile.patch(text, shortcut: "test.open", to: ShortcutOverride())
    #expect(try parsed(text.string).shortcuts.isEmpty)
    #expect(!text.string.contains("test.open"))
}

@Test func removingTheLastMemberTakesThePreviousComma() throws {
    var text = ConfigText("{\n  \"a\": 1,\n  \"b\": 2\n}")
    let object = try text.scan().object
    text.remove(object.member("b")!, from: object)
    #expect(text.string == "{\n  \"a\": 1\n}")
}

/// Random files with comments, trailing commas, CRLF and escapes, patched at random, always read
/// back as the values patched in.
@Test func randomPatchesReadBack() throws {
    var seed: UInt64 = 0x5EED
    func next(_ bound: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((seed >> 33) % UInt64(bound))
    }
    let flag = settings.first { $0.key == "a.flag" }!
    let count = settings.first { $0.key == "a.count" }!
    for _ in 0..<200 {
        let ending = next(2) == 0 ? "\n" : "\r\n"
        var lines = ["{"]
        if next(2) == 0 { lines.append("  // \"quoted\" /* not a block */ ,}") }
        if next(2) == 0 {
            lines.append("  \"a.count\": \(1 + next(10))" + (next(2) == 0 ? "," : ","))
        }
        if next(2) == 0 { lines.append("  /* block, with } and \" */ \"shade\": \"light\",") }
        lines.append("  \"folders\": []" + (next(2) == 0 ? "," : ""))
        lines.append("}")
        var text = ConfigText(lines.joined(separator: ending))
        var expectedFlag = false
        var expectedCount: Int?
        for _ in 0..<3 {
            if next(2) == 0 {
                expectedFlag = next(2) == 0
                text = try ConfigFile.patch(text, setting: flag, to: expectedFlag)
            } else {
                expectedCount = 1 + next(10)
                text = try ConfigFile.patch(text, setting: count, to: expectedCount!)
            }
        }
        let contents = try parsed(text.string)
        #expect((contents.values["a.flag"] as? Bool ?? false) == expectedFlag, "\(text.string)")
        if let expectedCount {
            #expect(contents.values["a.count"] as? Int == expectedCount, "\(text.string)")
        }
        #expect(!text.string.contains(ending == "\n" ? "\r" : "\n\n"), "\(text.string)")
    }
}

@Test func aSystemFolderOrTheHomeFolderIsRefusedAsAWatchedFolder() {
    func folder(_ path: String) -> String {
        #"{"folders": [{"path": "\#(path)", "kind": "local", "include": [], "exclude": [], "pollIntervalMinutes": 15}]}"#
    }
    for path in ["/", "/System", "/Users/", "/Volumes", "/usr/../usr", NSHomeDirectory()] {
        let found = problems(folder(path))
        #expect(found.count == 1, "\(path)")
        #expect(found.first?.contains("not a music folder") == true, "\(path): \(found)")
    }
    for path in ["/Volumes/music/library", NSHomeDirectory() + "/Music", "/Users/Shared/Music"] {
        #expect(throws: Never.self, "\(path)") { try parsed(folder(path)) }
    }
}

@Test func aFolderOnAShareIsItsShareAndThePathInsideIt() throws {
    func folder(_ fields: String) -> String {
        #"{"folders": [{\#(fields), "include": [], "exclude": [], "pollIntervalMinutes": 15}]}"#
    }
    let stored = folder(#""path": "library", "share": "smb://nas/music", "kind": "network""#)
    #expect(
        try parsed(stored).values["folders"] as? [WatchedFolder] == [
            WatchedFolder(
                path: "library", share: "smb://nas/music", kind: .network, pollIntervalMinutes: 15)
        ])
    let refused = [
        (#""path": "library", "share": "smb://nas", "kind": "network""#, "isn't a URL"),
        (#""path": "library", "share": "/Volumes/music", "kind": "network""#, "isn't a URL"),
        (#""path": "library", "share": "smb://nas/music", "kind": "local""#, "needs kind network"),
        (#""path": "/library", "share": "smb://nas/music", "kind": "network""#, "can't start"),
        (#""path": "a/../..", "share": "smb://nas/music", "kind": "network""#, "leaves share"),
        (#""path": "library", "kind": "network""#, "isn't absolute"),
    ]
    for (fields, problem) in refused {
        let found = problems(folder(fields))
        #expect(found.count == 1 && found[0].contains(problem), "\(fields): \(found)")
    }
}
