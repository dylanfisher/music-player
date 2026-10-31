import Foundation
import KeyChord
import Testing

@testable import Settings

private struct Schema: SettingsSchema {
    let flag = Setting("a.flag", title: "Flag", default: false, "A bool.")
    let count = Setting("a.count", title: "Count", default: 5, range: 1...10, "An integer.")
}

/// A config file in a fresh temporary folder that nothing else touches.
private func configURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("config-\(UUID().uuidString)/config.json")
}

@MainActor
private func store(_ url: URL, creating: Bool = true) -> ConfigStore<Schema> {
    ConfigStore(Schema(), fileURL: url, check: { _, _, _ in nil }, creating: creating)
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

@MainActor @Test func aMissingFileIsWrittenWithEveryDefault() throws {
    let url = configURL()
    let settings = store(url)
    #expect(try read(url) == settings.defaultText)
    #expect(settings[\.count] == 5)
    // A command-line mode reads without writing.
    let other = configURL()
    _ = try ConfigStore.strict(Schema(), fileURL: other, check: { _, _, _ in nil })
    #expect(!FileManager.default.fileExists(atPath: other.path))
}

@MainActor @Test func changesArePatchesThatKeepTheUsersText() throws {
    let url = configURL()
    try write("{\n  // mine\n  \"a.count\": 3 // three\n}\n", to: url)
    let settings = store(url)
    var changed: [Set<String>] = []
    settings.changed = { changed.append($0) }
    #expect(settings[\.count] == 3)
    try settings.set(\.count, to: 4)
    try settings.set(\.flag, to: true)
    #expect(try read(url).hasPrefix("{\n  // mine\n  \"a.count\": 4, // three\n"))
    #expect(changed == [["a.count"], ["a.flag"]])
    #expect(throws: ConfigError.self) { try settings.set(\.count, to: 11) }
    #expect(settings[\.count] == 4)
    try settings.set(key: "a.flag", json: false)
    #expect(settings[\.flag] == false)
}

@MainActor @Test func aBrokenFileAppliesNothingAndIsNeverWrittenOver() throws {
    let url = configURL()
    try write(#"{"a.count": 3}"#, to: url)
    let settings = store(url)
    var reported = 0
    settings.problemsChanged = { reported += 1 }
    try write(#"{"a.count": 3, "a.cont": 2}"#, to: url)
    settings.read(confirmed: true)
    #expect(settings.problems.map(\.description) == [#"line 1: unknown setting "a.cont""#])
    #expect(reported == 1)
    // The change waits, and memory shows it.
    try settings.set(\.flag, to: true)
    #expect(settings[\.flag])
    #expect(try read(url) == #"{"a.count": 3, "a.cont": 2}"#)
    // The fix is applied, with the waiting change on top.
    try write(#"{"a.count": 9}"#, to: url)
    settings.read(confirmed: true)
    #expect(settings.problems.isEmpty)
    #expect(settings[\.count] == 9)
    #expect(settings[\.flag])
    #expect(try read(url) == #"{"a.count": 9, "a.flag": true}"#)
}

@MainActor @Test func anEditIsReadBackAndADeletionMeansTheDefaults() throws {
    let url = configURL()
    let settings = store(url)
    var changed: [Set<String>] = []
    settings.changed = { changed.append($0) }
    try write(#"{"a.count": 2, "a.flag": true}"#, to: url)
    settings.read(confirmed: false)
    #expect(settings[\.count] == 2)
    try FileManager.default.removeItem(at: url)
    // A file found gone isn't taken as gone until a second read.
    settings.read(confirmed: false)
    #expect(settings[\.count] == 2)
    settings.read(confirmed: true)
    #expect(settings[\.count] == 5)
    #expect(changed == [["a.count", "a.flag"], ["a.count", "a.flag"]])
}

@MainActor @Test func shortcutsAreKeptAndWritten() throws {
    let url = configURL()
    let settings = store(url)
    let override = ShortcutOverride(primary: .chord(KeyChord("j", .command)))
    settings.setShortcut("test.open", to: override)
    #expect(settings.shortcuts == ["test.open": override])
    let reread = try ConfigStore.strict(Schema(), fileURL: url, check: { _, _, _ in nil })
    #expect(reread.shortcuts == ["test.open": override])
    settings.setShortcut("test.open", to: ShortcutOverride())
    #expect(settings.shortcuts.isEmpty)
    #expect(!(try read(url)).contains("test.open"))
}

@MainActor @Test func severalShortcutsChangeAsOne() throws {
    let url = configURL()
    let settings = store(url)
    var changed: [Set<String>] = []
    settings.changed = { changed.append($0) }
    let chord = KeyChord("j", .command)
    settings.setShortcuts([
        "test.open": ShortcutOverride(primary: .chord(chord)),
        "test.close": ShortcutOverride(primary: .removed),
    ])
    #expect(changed == [[ConfigFile.shortcutsKey]])
    let reread = try ConfigStore.strict(Schema(), fileURL: url, check: { _, _, _ in nil })
    #expect(reread.shortcuts.count == 2)
}

@MainActor @Test func aSymbolicLinkIsWrittenThrough() throws {
    let target = configURL()
    try write(#"{"a.count": 3}"#, to: target)
    let link = configURL()
    try FileManager.default.createDirectory(
        at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let settings = store(link)
    try settings.set(\.count, to: 6)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    #expect(try read(target) == #"{"a.count": 6}"#)
}

@MainActor @Test func theStrictReadThrowsOnAnyProblem() throws {
    let url = configURL()
    try write(#"{"a.count": 0}"#, to: url)
    #expect(throws: ConfigError.self) {
        try ConfigStore.strict(Schema(), fileURL: url, check: { _, _, _ in nil })
    }
}

/// Waits on the main actor, so the store's timers can fire, until `done` or `seconds` pass.
@MainActor
private func wait(seconds: Double, until done: () throws -> Bool) async rethrows {
    let deadline = Date().addingTimeInterval(seconds)
    while try !done(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
}

@MainActor @Test func aChangeMadeWhileAnEmptyReadIsConfirmedIsWritten() async throws {
    let url = configURL()
    try write(#"{"a.count": 3}"#, to: url)
    let settings = store(url)
    // An editor's save in place passes through an empty file.
    try write("", to: url)
    settings.read(confirmed: false)
    try settings.set(\.flag, to: true)
    try write(#"{"a.count": 3}"#, to: url)
    try await wait(seconds: 2) { try read(url).contains("a.flag") }
    #expect(try read(url) == #"{"a.count": 3, "a.flag": true}"#)
}

@MainActor @Test func aFileDeletedAndRecreatedIsReadAsRecreated() async throws {
    let url = configURL()
    try write(#"{"a.count": 3}"#, to: url)
    let settings = store(url)
    try FileManager.default.removeItem(at: url)
    settings.read(confirmed: false)
    try write(#"{"a.count": 7}"#, to: url)
    await wait(seconds: 2) { settings[\.count] == 7 }
    #expect(settings[\.count] == 7)
    #expect(settings.problems.isEmpty)
}

@MainActor @Test func aNewFileThatCouldntBeWrittenIsRetried() async throws {
    let url = configURL()
    // A folder that can't be written to.
    let folder = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o555])
    let settings = store(url)
    #expect(settings.writeFailure != nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    await wait(seconds: 3) { FileManager.default.fileExists(atPath: url.path) }
    #expect(try read(url) == settings.defaultText)
    #expect(settings.writeFailure == nil)
}

@MainActor @Test func aFileThatCantBeReadIsNeverWrittenOver() throws {
    let url = configURL()
    let settings = store(url, creating: false)
    try write(#"{"a.count": 3}"#, to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }
    try settings.set(\.flag, to: true)
    #expect(settings.writeFailure != nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    #expect(try read(url) == #"{"a.count": 3}"#)
}
