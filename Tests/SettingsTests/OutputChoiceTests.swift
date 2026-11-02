import Testing

@testable import Settings

private let devices = [
    FoundOutput(id: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers"),
    FoundOutput(id: "ADI-2", name: "ADI-2 DAC"),
]
private let renderers = [FoundOutput(id: "uuid:denon", name: "Denon AVR")]

@Test func thePickerListsTheDefaultThenDevicesThenRenderers() {
    let options = outputOptions(devices: devices, renderers: renderers, current: .systemDefault)
    #expect(
        options.map(\.title) == [
            "System Default", "MacBook Pro Speakers", "ADI-2 DAC", "Denon AVR",
        ])
    #expect(
        options.map(\.choice) == [
            .systemDefault, .device(uid: "BuiltInSpeakerDevice"), .device(uid: "ADI-2"),
            .renderer(udn: "uuid:denon"),
        ])
}

@Test func aChosenOutputThatIsntFoundStaysListedByItsID() {
    let gone = outputOptions(devices: devices, renderers: [], current: .device(uid: "USB-9"))
    #expect(gone.map(\.title).dropFirst(3).first == "USB-9 (not connected)")
    let unfound = outputOptions(
        devices: [], renderers: [], current: .renderer(udn: "uuid:sonos"))
    #expect(unfound.map(\.title) == ["System Default", "uuid:sonos (not found)"])
    #expect(
        outputOptions(devices: devices, renderers: [], current: .device(uid: "ADI-2")).count == 3)
}

@Test func theRendererIsTheChoiceWhileSetAndPickingOneKeepsTheDevice() {
    #expect(
        OutputChoice(deviceUID: "ADI-2", renderer: "uuid:denon") == .renderer(udn: "uuid:denon"))
    #expect(OutputChoice(deviceUID: "ADI-2", renderer: nil) == .device(uid: "ADI-2"))
    #expect(OutputChoice(deviceUID: nil, renderer: nil) == .systemDefault)
    #expect(OutputChoice.device(uid: "B").settings(deviceUID: "A") == ("B", nil))
    #expect(OutputChoice.renderer(udn: "R").settings(deviceUID: "A") == ("A", "R"))
    #expect(OutputChoice.systemDefault.settings(deviceUID: "A") == (nil, nil))
}

@Test func aChoiceReadsBackFromItsText() {
    for choice in [
        OutputChoice.systemDefault, .device(uid: "ADI-2:out"), .renderer(udn: "uuid:denon"),
    ] {
        #expect(OutputChoice(text: choice.text) == choice)
    }
    #expect(OutputChoice(text: "output:device:") == nil)
    #expect(OutputChoice(text: "output:speaker:x") == nil)
    #expect(OutputChoice(text: "command:x") == nil)
}
