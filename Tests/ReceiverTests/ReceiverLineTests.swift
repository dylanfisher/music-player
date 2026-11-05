import Testing

@testable import Receiver

private func line(_ text: String) -> ReceiverLine { ReceiverLine(Array(text.utf8)[...]) }

private func volume(_ halfSteps: Int) -> ReceiverEvent {
    .volume(ReceiverVolume(halfSteps: halfSteps)!)
}

@Test func statusLinesBecomeEvents() {
    let cases: [(String, ReceiverLine)] = [
        ("PWON", .event(.power(true))), ("PWSTANDBY", .event(.power(false))),
        ("MV80", .event(volume(160))), ("MV805", .event(volume(161))), ("MV00", .event(volume(0))),
        ("MV005", .event(volume(1))), ("MV98", .event(volume(196))), ("MV99", .event(volume(0))),
        ("MUON", .event(.mute(true))), ("MUOFF", .event(.mute(false))),
        ("SICD", .event(.input(.cd))), ("SISAT/CBL", .event(.input(.cableSatellite))),
        ("MSPURE DIRECT", .event(.soundMode("PURE DIRECT"))),
        ("MSDOLBY AUDIO-DD+DSUR", .event(.soundMode("DOLBY AUDIO-DD+DSUR"))),
    ]
    for (text, expected) in cases { #expect(line(text) == expected, "\(text)") }
}

@Test func unknownValuesAreReportedAndOtherCommandsIgnored() {
    for text in [
        "MV985", "MV995", "MV9", "MV1234", "MV-1", "MV8 0", "MVUP", "PWMAYBE", "MU", "MUon",
        "MS" + String(repeating: "A", count: 26), "MS",
    ] {
        #expect(line(text) == .unknownValue(text), "\(text)")
    }
    // An input the app has no name for: the model shows none, and it's reported.
    #expect(line("SIHEOS MUSIC") == .event(.input(nil)))
    for text in [
        "MVMAX 98", "MVMAX 805", "CVFL 50", "MSQUICK1", "Z2ON", "SSINFAISFSV 441", "", "P",
    ] {
        #expect(line(text) == .ignored, "\(text)")
    }
    for bytes: [UInt8] in [[0x4D, 0x56, 0xFF], [0x50, 0x57, 0x00], [0x1B, 0x5B], [0x7F]] {
        #expect(ReceiverLine(bytes[...]) == .notText)
    }
}

@Test func commandsAreBuiltFromTypedValues() {
    let cases: [(ReceiverCommand, String)] = [
        (.volumeUp, "MVUP\r"), (.volumeDown, "MVDOWN\r"),
        (.setVolume(ReceiverVolume(decibels: "-30.5")!), "MV495\r"),
        (.setVolume(ReceiverVolume(decibels: "-80")!), "MV00\r"),
        (.setVolume(ReceiverVolume(decibels: "-75.5")!), "MV045\r"),
        (.setVolume(ReceiverVolume(decibels: "+18")!), "MV98\r"),
        (.mute(true), "MUON\r"), (.mute(false), "MUOFF\r"),
        (.soundMode(.pureDirect), "MSPURE DIRECT\r"), (.input(.cableSatellite), "SISAT/CBL\r"),
        (.power(true), "PWON\r"), (.power(false), "PWSTANDBY\r"),
    ]
    for (command, text) in cases { #expect(command.line == Array(text.utf8)) }
    // Every command fits a line, and reads back as what it sets.
    var all: [ReceiverCommand] = [.volumeUp, .volumeDown, .mute(true), .power(false)]
    all += ReceiverVolume.halfStepRange.map { .setVolume(ReceiverVolume(halfSteps: $0)!) }
    all +=
        ReceiverInput.allCases.map { .input($0) }
        + ReceiverSoundMode.allCases.map { .soundMode($0) }
    for command in all {
        let bytes = command.line
        #expect(bytes.count <= ReceiverConnection.lineCap)
        #expect(bytes.last == 0x0D)
        #expect(bytes.dropLast().allSatisfy { $0 >= 0x20 && $0 < 0x7F })
        switch command {
        case .setVolume(let volume):
            #expect(ReceiverLine(bytes.dropLast()) == .event(.volume(volume)))
        case .input(let input): #expect(ReceiverLine(bytes.dropLast()) == .event(.input(input)))
        default: break
        }
    }
}

@Test func onlyWholeAndHalfDecibelsInRangeAreAVolume() {
    #expect(ReceiverVolume(decibels: "0")?.halfSteps == 160)
    #expect(ReceiverVolume(decibels: "-0.5")?.decibels == -0.5)
    for text in ["-80.5", "18.5", "-30.25", "abc", "", "nan", "inf", "-", "1e400", "100", "0x10"] {
        #expect(ReceiverVolume(decibels: text) == nil, "\(text)")
    }
}

@Test func aSlidersValueRoundsToTheNearestHalfDecibel() {
    #expect(ReceiverVolume(decibels: -35.3)?.decibels == -35.5)
    #expect(ReceiverVolume(decibels: -35.2)?.decibels == -35)
    #expect(ReceiverVolume(decibels: -80.2)?.decibels == -80)
    #expect(ReceiverVolume(decibels: -81) == nil)
    #expect(ReceiverVolume(decibels: .nan) == nil)
}

@Test func theModelTakesOnlyWhatTheReceiverReports() {
    var state = ReceiverState()
    state.apply(.power(true))
    state.apply(volume(100))
    state.apply(.soundMode("STEREO"))
    state.apply(.input(.cd))
    #expect(state.isOn == true)
    #expect(state.volume?.decibels == -30)
    #expect(state.isIn(.stereo))
    #expect(!state.isIn(.pureDirect))
    state.apply(.input(nil))
    #expect(state.input == nil)
}
