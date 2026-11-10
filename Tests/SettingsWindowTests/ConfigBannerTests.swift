import AppKit
import Settings
import Testing

@testable import SettingsWindow

@MainActor @Test func theBannerNamesTheFirstProblemAndHidesWhenTheFileIsGood() {
    let banner = ConfigBanner()
    banner.show(
        problems: [
            ConfigProblem(line: 3, message: #"unknown setting "a.flg""#),
            ConfigProblem(line: 5, message: "isn't valid JSON"),
        ], writeFailure: nil, path: "/x/config.json", stateFailure: nil,
        stateDiscarded: [], configEdits: 1)
    #expect(!banner.view.isHidden)
    #expect(banner.text.hasPrefix(#"config.json: line 3: unknown setting "a.flg" (1 more)."#))
    banner.show(
        problems: [], writeFailure: nil, path: "/x/config.json", stateFailure: nil,
        stateDiscarded: [], configEdits: 1)
    #expect(banner.view.isHidden)
    banner.show(
        problems: [], writeFailure: "disk full", path: "/x/config.json", stateFailure: nil,
        stateDiscarded: [], configEdits: 1)
    #expect(banner.text == "config.json: couldn't save: disk full.")
    banner.show(
        problems: [], writeFailure: nil, path: "/x/config.json", stateFailure: "disk full",
        stateDiscarded: [], configEdits: 1)
    #expect(!banner.view.isHidden)
    #expect(banner.text == "couldn't save the window layout: disk full.")
    banner.show(
        problems: [], writeFailure: nil, path: "/x/config.json", stateFailure: nil,
        stateDiscarded: ["the saved window layout was reset: not JSON"], configEdits: 1)
    #expect(banner.text == "the saved window layout was reset: not JSON.")
    #expect(banner.removeButtonTitle == nil)
}

@MainActor @Test func anObsoleteKeyOffersItsRemovalAndSaysTheRestApplies() {
    let banner = ConfigBanner()
    var removed = 0
    banner.removeObsoleteSettings = { removed += 1 }
    let old = ConfigProblem(line: 3, message: #"unknown setting "a.old""#, obsoleteKey: ["a.old"])
    func show(_ problems: [ConfigProblem]) {
        banner.show(
            problems: problems, writeFailure: nil, path: "/x/config.json", stateFailure: nil,
            stateDiscarded: [], configEdits: 1)
    }
    show([old])
    #expect(
        banner.text == #"config.json: line 3: unknown setting "a.old". The rest of it applies."#)
    #expect(banner.removeButtonTitle == "Remove Obsolete Setting")
    show([old, ConfigProblem(line: 4, message: "x", obsoleteKey: ["b.old"])])
    #expect(banner.removeButtonTitle == "Remove Obsolete Settings")
    show([old, ConfigProblem(line: 5, message: "\"a.count\": 11 is outside 1...10")])
    #expect(
        banner.text.hasSuffix("Nothing in it applies, and nothing can change, until it's fixed."))
    #expect(banner.removeButtonTitle == "Remove Obsolete Setting")
    banner.perform(NSSelectorFromString("remove"))
    #expect(removed == 1)
    show([])
    #expect(banner.removeButtonTitle == nil)
    banner.show(
        problems: [], writeFailure: nil, path: "/x/config.json", unwatched: "not watched",
        stateFailure: nil, stateDiscarded: [], configEdits: 1)
    #expect(banner.text == "config.json: not watched.")
}

@MainActor @Test func aWarningClosedStaysHiddenUntilTheFileIsEditedAndABlockingOneCantClose() {
    let banner = ConfigBanner()
    let token = ConfigProblem(
        line: 2, message: #"unknown setting "discogs.token""#, obsoleteKey: ["discogs.token"])
    func show(_ problems: [ConfigProblem], edits: Int, writeFailure: String? = nil) {
        banner.show(
            problems: problems, writeFailure: writeFailure, path: "/x/config.json",
            stateFailure: nil, stateDiscarded: [], configEdits: edits)
    }
    show([token], edits: 1)
    #expect(banner.canDismiss)
    banner.dismissWarnings()
    #expect(banner.view.isHidden)
    show([token], edits: 1)
    #expect(banner.view.isHidden, "a reread of the same file, or the app's own change")
    show([token], edits: 1, writeFailure: "disk full")
    #expect(!banner.view.isHidden)
    #expect(banner.text == "config.json: couldn't save: disk full.", "only the warning hides")
    #expect(!banner.canDismiss)
    show([token], edits: 2)
    #expect(!banner.view.isHidden, "back once the file is edited")
    #expect(banner.text.hasPrefix(#"config.json: line 2: unknown setting "discogs.token""#))

    let blocking = ConfigProblem(line: 3, message: "isn't valid JSON")
    show([token, blocking], edits: 3)
    #expect(!banner.canDismiss)
    banner.dismissWarnings()
    #expect(!banner.view.isHidden, "a problem that blocks the file can't be closed")
    #expect(banner.text.hasSuffix(ConfigBanner.blockedText))
}

@MainActor @Test func aClosedWarningStaysHiddenWhenTheAppsOwnWriteMovesItsLine() {
    let banner = ConfigBanner()
    func token(line: Int) -> ConfigProblem {
        ConfigProblem(
            line: line, message: #"unknown setting "discogs.token""#,
            obsoleteKey: ["discogs.token"])
    }
    let old = ConfigProblem(line: 9, message: #"unknown setting "a.old""#, obsoleteKey: ["a.old"])
    func show(_ problems: [ConfigProblem]) {
        banner.show(
            problems: problems, writeFailure: nil, path: "/x/config.json", stateFailure: nil,
            stateDiscarded: [], configEdits: 1)
    }
    show([token(line: 2), old])
    banner.dismissWarnings()
    // A key the app added above it, which isn't an edit from outside.
    show([
        token(line: 5), ConfigProblem(line: 12, message: old.message, obsoleteKey: old.obsoleteKey),
    ])
    #expect(banner.view.isHidden)
    // Remove Obsolete Setting took one out, moving the other.
    show([token(line: 4)])
    #expect(banner.view.isHidden)
}

/// A line saying what of the saved layout was reset closes, alone or under a problem that
/// blocks the config file, which stays; closing has the state file saved without it, and a
/// failed save shows as any.
@MainActor @Test func aResetLineClosesAndHasTheStateFileSaved() {
    let banner = ConfigBanner()
    var closed = 0
    banner.closeStateDiscard = { closed += 1 }
    let reset = "the saved Discogs Tagger Sheets setting was reset: x: unknown key"
    func show(_ problems: [ConfigProblem], discarded: [String], stateFailure: String? = nil) {
        banner.show(
            problems: problems, writeFailure: nil, path: "/x/config.json",
            stateFailure: stateFailure, stateDiscarded: discarded, configEdits: 1)
    }
    show([], discarded: [reset])
    #expect(banner.text == "\(reset).")
    #expect(banner.canDismiss)
    banner.dismissWarnings()
    #expect(closed == 1)
    show([], discarded: [])
    #expect(banner.view.isHidden, "hidden once the file is saved")

    show([], discarded: [reset], stateFailure: "disk full")
    #expect(banner.text == "couldn't save the window layout: disk full (1 more).")
    #expect(!banner.view.isHidden, "a failed save is never hidden")

    let blocking = ConfigProblem(line: 3, message: "isn't valid JSON")
    show([blocking], discarded: [reset])
    #expect(banner.canDismiss)
    banner.dismissWarnings()
    #expect(closed == 2)
    show([blocking], discarded: [])
    #expect(!banner.view.isHidden, "the blocking problem stays")
    #expect(!banner.canDismiss)
}
