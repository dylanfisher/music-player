import Foundation
import Testing

@testable import Receiver

/// What the owner's AVR-X1800H sent on connecting, as `--capture-renderers` saved it: a time,
/// a tab and the line, after a comment line. The address in the comment is scrubbed.
private func capturedLines() throws -> [String] {
    let url = try #require(
        Bundle.module.url(forResource: "Fixtures/denon-status-lines", withExtension: "txt"))
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        .compactMap { $0.split(separator: "\t", maxSplits: 1).last.map(String.init) }
        .filter { !$0.hasPrefix("#") }
}

@Test func theReceiversOwnLinesBuildItsState() throws {
    var state = ReceiverState()
    var unknown: [String] = []
    for line in try capturedLines() {
        switch ReceiverLine(Array(line.utf8)[...]) {
        case .event(let event): state.apply(event)
        case .unknownValue(let text): unknown.append(text)
        case .ignored: break
        case .notText: Issue.record("\(line.debugDescription) isn't text")
        }
    }
    #expect(unknown == [])
    // On HEOS (NET), the input the UPnP stream plays on, in Direct, at MV30.
    #expect(state.isOn == true)
    #expect(state.isMuted == false)
    #expect(state.input == .network)
    #expect(state.soundMode == "DIRECT")
    #expect(state.isIn(.direct))
    #expect(state.volume?.decibels == -50)
}
