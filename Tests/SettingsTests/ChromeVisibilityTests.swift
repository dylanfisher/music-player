import Testing

@testable import Settings

@Test func distractionFreeHidesEverythingThenShowsWhatShowed() {
    var hid: ChromeVisibility?
    let some = ChromeVisibility(toolbar: true, sidebar: false, statusBar: true)
    let off = some.toggled(hid: &hid)
    #expect(off == .hidden)
    #expect(hid == some)
    let back = off.toggled(hid: &hid)
    #expect(back == some)
    #expect(hid == nil)
}

@Test func distractionFreeWithNothingToRestoreShowsEverything() {
    var hid: ChromeVisibility?
    // As after a relaunch with everything hidden.
    #expect(ChromeVisibility.hidden.toggled(hid: &hid) == .shown)
    #expect(hid == nil)
}

@Test func showingOnePartByHandForgetsNothingAndHidesAgain() {
    var hid: ChromeVisibility? = .shown
    // The sidebar shown by hand while the mode was on: the next press hides it again.
    let sidebar = ChromeVisibility(toolbar: false, sidebar: true, statusBar: false)
    #expect(sidebar.toggled(hid: &hid) == .hidden)
    #expect(hid == sidebar)
}
