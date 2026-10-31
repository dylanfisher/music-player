import Settings
import Testing

@testable import SettingsWindow

@MainActor @Test func theBannerNamesTheFirstProblemAndHidesWhenTheFileIsGood() {
    let banner = ConfigBanner()
    banner.show(
        problems: [
            ConfigProblem(line: 3, message: #"unknown setting "a.flg""#),
            ConfigProblem(line: 5, message: "isn't valid JSON"),
        ], writeFailure: nil, path: "/x/config.json")
    #expect(!banner.view.isHidden)
    #expect(banner.text.hasPrefix(#"config.json: line 3: unknown setting "a.flg" (1 more)."#))
    banner.show(problems: [], writeFailure: nil, path: "/x/config.json")
    #expect(banner.view.isHidden)
    banner.show(problems: [], writeFailure: "disk full", path: "/x/config.json")
    #expect(banner.text == "config.json: couldn't save: disk full.")
}
