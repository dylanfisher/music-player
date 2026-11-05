import Testing

@testable import HALOutput

@Test func aSerialNumberAtTheEndOfADeviceNameIsLeftOut() {
    let names = ["ADI-2 DAC (57850288)", "MacBook Pro Speakers"]
    #expect(deviceDisplayName("ADI-2 DAC (57850288)", among: names) == "ADI-2 DAC")
    #expect(deviceDisplayName("MacBook Pro Speakers", among: names) == "MacBook Pro Speakers")
}

@Test func twoDevicesThatDifferOnlyByTheirSerialKeepIt() {
    let names = ["ADI-2 DAC (57850288)", "ADI-2 DAC (57850299)"]
    #expect(deviceDisplayName("ADI-2 DAC (57850288)", among: names) == "ADI-2 DAC (57850288)")
    let named = ["ADI-2 DAC (57850288)", "ADI-2 DAC"]
    #expect(deviceDisplayName("ADI-2 DAC (57850288)", among: named) == "ADI-2 DAC (57850288)")
}

@Test func shortNumbersAndOtherTextInParenthesesStay() {
    for name in ["Studio Display (2)", "Scarlett 2i2 (USB)", "DAC (1234567a)", "(12345678)"] {
        #expect(deviceDisplayName(name, among: [name]) == name)
    }
}
