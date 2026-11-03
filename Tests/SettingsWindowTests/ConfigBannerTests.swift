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
        stateDiscarded: nil)
    #expect(!banner.view.isHidden)
    #expect(banner.text.hasPrefix(#"config.json: line 3: unknown setting "a.flg" (1 more)."#))
    banner.show(
        problems: [], writeFailure: nil, path: "/x/config.json", stateFailure: nil,
        stateDiscarded: nil)
    #expect(banner.view.isHidden)
    banner.show(
        problems: [], writeFailure: "disk full", path: "/x/config.json", stateFailure: nil,
        stateDiscarded: nil)
    #expect(banner.text == "config.json: couldn't save: disk full.")
    banner.show(
        problems: [], writeFailure: nil, path: "/x/config.json", stateFailure: "disk full",
        stateDiscarded: nil)
    #expect(!banner.view.isHidden)
    #expect(banner.text == "couldn't save the window layout: disk full.")
    banner.show(
        problems: [], writeFailure: nil, path: "/x/config.json", stateFailure: nil,
        stateDiscarded: "not JSON")
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
            stateDiscarded: nil)
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
        stateFailure: nil, stateDiscarded: nil)
    #expect(banner.text == "config.json: not watched.")
}
