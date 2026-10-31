import Testing

@testable import DisplayText

@Test func clockShowsMinutesAndSecondsAndHoursOnlyWhenThereAreSome() {
    #expect(clock(312.4) == "5:12")
    #expect(clock(5) == "0:05")
    #expect(clock(3725) == "1:02:05")
    #expect(clock(-3) == "0:00")
}

@Test(arguments: [
    (44_100.0, "44.1"), (96_000.0, "96"), (705_600.0, "705.6"), (768_000.0, "768"),
])
func formatsKilohertz(hertz: Double, expected: String) {
    #expect(kilohertz(hertz) == expected)
}
