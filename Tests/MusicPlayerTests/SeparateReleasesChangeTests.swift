import Foundation
import Settings
import Testing

@testable import MusicPlayer

/// A config file of its own in a temporary folder, with Separate Releases asked about as the
/// app asks: on each change, answered with the answer given.
@MainActor private final class Asking {
    let settings: ConfigStore<AppSettings>
    let change: SeparateReleasesChange
    var answers: [SeparateReleasesChange.Answer] = []

    init(inUse: Bool) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("separate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        settings = ConfigStore(
            AppSettings(), fileURL: AppPaths(home: home).configFile, check: try shortcutCheck(),
            creating: true)
        change = SeparateReleasesChange(inUse: inUse)
    }

    /// Sets the setting to `value`; when that asks, answers `rescan` and does what it says.
    func set(_ value: Bool, answering rescan: Bool) throws {
        try settings.set(\.separateReleases, to: value)
        guard change.asks(settings[\.separateReleases]) else { return }
        let answer = change.answer(rescan: rescan, setting: settings[\.separateReleases])
        answers.append(answer)
        if answer == .revert { try set(change.inUse, answering: rescan) }
    }
}

@MainActor @Test func cancelSetsSeparateReleasesBackAndAsksOnce() throws {
    let asking = try Asking(inUse: false)
    try asking.set(true, answering: false)
    #expect(asking.answers == [.revert], "the revert doesn't ask again")
    #expect(asking.settings[\.separateReleases] == false)
}

@MainActor @Test func rescanNowRelaunchesForTheValueSet() throws {
    let asking = try Asking(inUse: true)
    try asking.set(false, answering: true)
    #expect(asking.answers == [.relaunch(false)])
}

@MainActor @Test func theValueInUseAsksNothing() throws {
    let asking = try Asking(inUse: true)
    try asking.set(true, answering: true)
    #expect(asking.answers.isEmpty)
    // Set back while the question was up: neither a relaunch nor a write.
    let change = SeparateReleasesChange(inUse: false)
    #expect(change.answer(rescan: true, setting: false) == .nothing)
    #expect(change.answer(rescan: false, setting: false) == .nothing)
}
