import CoreAudio
import HALRender
import RingBuffer
import Testing

/// Runs one IO cycle into a `count`-byte output buffer and returns what the device would receive.
private func render(_ render: OpaquePointer, bytes count: Int = 8) -> [UInt8] {
    var output = [UInt8](repeating: 0xAA, count: count)
    var time = AudioTimeStamp()
    var input = AudioBufferList()
    output.withUnsafeMutableBytes { bytes in
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(count), mData: bytes.baseAddress))
        let status = HALRenderIOProc(
            0, &time, &input, &time, &list, &time, UnsafeMutableRawPointer(render))
        #expect(status == noErr)
    }
    return output
}

/// A ring buffer and render state that live for one test.
private final class Fixture {
    let source: OpaquePointer
    let state: OpaquePointer

    /// Opaque by default, for the tests of how bytes are copied and skipped, which fades would
    /// change. 800 Hz makes a fade 4 frames.
    init(
        samples: HALRenderSampleKind = HALRenderSamplesOpaque, channels: Int = 1,
        sampleRateHz: Double = 800, capacity: Int = 64
    ) throws {
        source = try #require(RingBufferCreate(capacity))
        let width = samples == HALRenderSamplesOpaque ? 1 : sampleBytes(samples)
        state = try #require(
            HALRenderCreate(source, samples, UInt32(width * channels), sampleRateHz))
    }

    deinit {
        HALRenderDestroy(state)
        RingBufferDestroy(source)
    }

    func write(_ bytes: [UInt8]) {
        #expect(RingBufferWrite(source, bytes, bytes.count) == bytes.count)
    }
}

@Test func copiesSourceBytesUnchanged() throws {
    let fixture = try Fixture()
    let samples: [UInt8] = [1, 2, 3, 4, 0xFF, 0xFE, 0x80, 0x7F]
    fixture.write(samples)

    #expect(render(fixture.state) == samples)
    #expect(HALRenderUnderrunBytes(fixture.state) == 0)
    #expect(HALRenderConsumedBytes(fixture.state) == 8)
}

@Test func padsShortfallWithSilenceAndCountsIt() throws {
    let fixture = try Fixture()
    fixture.write([UInt8](repeating: 9, count: 3))

    #expect(render(fixture.state) == [9, 9, 9, 0, 0, 0, 0, 0])
    #expect(HALRenderUnderrunBytes(fixture.state) == 5)
    #expect(HALRenderConsumedBytes(fixture.state) == 3)
}

@Test func drainingSilenceIsNotAnUnderrun() throws {
    let fixture = try Fixture()
    fixture.write([UInt8](repeating: 9, count: 3))
    HALRenderSetDraining(fixture.state, true)

    #expect(render(fixture.state) == [9, 9, 9, 0, 0, 0, 0, 0])
    #expect(HALRenderUnderrunBytes(fixture.state) == 0)

    HALRenderSetDraining(fixture.state, false)
    _ = render(fixture.state)
    #expect(HALRenderUnderrunBytes(fixture.state) == 8)
}

@Test func discardSkipsOnlyWhatWasWrittenBeforeIt() throws {
    let fixture = try Fixture()
    fixture.write([1, 1, 1, 1, 1, 1])
    #expect(render(fixture.state, bytes: 2) == [1, 1])

    // Seek: drop the 4 old bytes still queued; the new audio is written straight after.
    HALRenderDiscard(fixture.state, 0, 6)
    fixture.write([2, 2, 2, 2])

    #expect(render(fixture.state, bytes: 4) == [2, 2, 2, 2])
    #expect(HALRenderConsumedBytes(fixture.state) == 10)
    #expect(HALRenderUnderrunBytes(fixture.state) == 0)
}

@Test func aDiscardAheadPlaysUpToItThenSkipsMidBuffer() throws {
    let fixture = try Fixture()
    // The current track's tail (1-4) and an old next track (5-8) are queued.
    fixture.write([1, 2, 3, 4, 5, 6, 7, 8])
    #expect(render(fixture.state, bytes: 2) == [1, 2])

    // Replace the next track: drop bytes 4..<8 and queue its replacement after them.
    HALRenderDiscard(fixture.state, 4, 8)
    fixture.write([9, 10, 11, 12])
    #expect(render(fixture.state, bytes: 6) == [3, 4, 9, 10, 11, 12])
    #expect(HALRenderConsumedBytes(fixture.state) == 12)
    #expect(HALRenderUnderrunBytes(fixture.state) == 0)
}

@Test func aNewerDiscardReplacesOneNotYetReached() throws {
    let fixture = try Fixture()
    fixture.write([1, 2, 3, 4, 5, 6])
    HALRenderDiscard(fixture.state, 4, 6)
    // A seek before the IO proc reaches byte 4 drops everything instead.
    HALRenderDiscard(fixture.state, 0, 6)
    fixture.write([7, 8])
    #expect(render(fixture.state, bytes: 2) == [7, 8])
}

@Test func refillAfterADiscardIsNotAnUnderrunUntilABufferIsFull() throws {
    let fixture = try Fixture()
    fixture.write([1, 1, 1, 1])
    HALRenderDiscard(fixture.state, 0, 4)

    #expect(render(fixture.state) == [0, 0, 0, 0, 0, 0, 0, 0])
    fixture.write([2, 2, 2, 2, 2, 2, 2, 2])
    #expect(render(fixture.state) == [2, 2, 2, 2, 2, 2, 2, 2])
    #expect(HALRenderUnderrunBytes(fixture.state) == 0)

    _ = render(fixture.state)
    #expect(HALRenderUnderrunBytes(fixture.state) == 8)
}

private func bytes<T>(_ values: [T]) -> [UInt8] {
    values.withUnsafeBytes { Array($0) }
}

private func values<T>(_ bytes: [UInt8], as: T.Type) -> [T] {
    bytes.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
}

@Test func gainRampsAcrossOneBufferThenHolds() throws {
    let fixture = try Fixture(samples: HALRenderSamplesInt32)
    HALRenderSetGain(fixture.state, 0.5)
    fixture.write(bytes([Int32](repeating: 1000, count: 4)))
    fixture.write(bytes([Int32](repeating: 1000, count: 4)))

    #expect(values(render(fixture.state, bytes: 16), as: Int32.self) == [875, 750, 625, 500])
    #expect(values(render(fixture.state, bytes: 16), as: Int32.self) == [500, 500, 500, 500])
}

@Test func gainScalesEverySampleKind() throws {
    let int16 = try Fixture(samples: HALRenderSamplesInt16)
    HALRenderSetGain(int16.state, 0.5)
    _ = render(int16.state)  // the ramp
    int16.write(bytes([Int16](arrayLiteral: 1000, -1000, 32767, -32768)))
    #expect(values(render(int16.state), as: Int16.self) == [500, -500, 16383, -16384])

    let int24 = try Fixture(samples: HALRenderSamplesInt24)
    HALRenderSetGain(int24.state, 0.5)
    _ = render(int24.state, bytes: 6)
    // 1000 and -1000 as packed little-endian 24-bit.
    int24.write([0xE8, 0x03, 0x00, 0x18, 0xFC, 0xFF])
    #expect(render(int24.state, bytes: 6) == [0xF4, 0x01, 0x00, 0x0C, 0xFE, 0xFF])

    let float = try Fixture(samples: HALRenderSamplesFloat32)
    HALRenderSetGain(float.state, 0.25)
    _ = render(float.state)
    float.write(bytes([Float](arrayLiteral: 1, -0.5)))
    #expect(values(render(float.state), as: Float.self) == [0.25, -0.125])
}

@Test func unityGainAfterAChangeIsBitExactAgain() throws {
    let fixture = try Fixture(samples: HALRenderSamplesInt32)
    HALRenderSetGain(fixture.state, 0.5)
    _ = render(fixture.state)
    HALRenderSetGain(fixture.state, 1)
    _ = render(fixture.state)  // ramps back up

    let samples: [Int32] = [Int32.max, Int32.min]
    fixture.write(bytes(samples))
    #expect(values(render(fixture.state), as: Int32.self) == samples)
}

@Test func opaqueBytesPassUnchangedWhateverTheGain() throws {
    let fixture = try Fixture(samples: HALRenderSamplesOpaque)
    HALRenderSetGain(fixture.state, 0.5)
    // Two DoP frames: markers 0x05 and 0xFA over DSD bytes, 24 bits aligned high in 32.
    let frames: [UInt8] = [
        0, 0x69, 0x96, 0x05, 0, 0x69, 0x96, 0x05, 0, 0x12, 0x34, 0xFA, 0, 0x56, 0x78, 0xFA,
    ]
    fixture.write(frames)
    #expect(render(fixture.state, bytes: 16) == frames)
    HALRenderSetGain(fixture.state, 0)
    fixture.write(frames)
    #expect(render(fixture.state, bytes: 16) == frames)
}

// MARK: Fades

private func sampleBytes(_ kind: HALRenderSampleKind) -> Int {
    switch kind {
    case HALRenderSamplesInt16: 2
    case HALRenderSamplesInt24: 3
    default: 4
    }
}

/// Runs one IO cycle of `frames` mono Int32 frames.
private func renderInt32(_ fixture: Fixture, frames: Int) -> [Int32] {
    values(render(fixture.state, bytes: frames * 4), as: Int32.self)
}

@Test func aFadeLastsAboutFiveMilliseconds() {
    #expect(HALRenderFadeFrames(44_100) == 221)
    #expect(HALRenderFadeFrames(192_000) == 960)
    #expect(HALRenderFadeFrames(800) == 4)
    #expect(HALRenderFadeFrames(10) == 1)
}

@Test func aPauseFadesOutThenTakesNothingAndAPlayFadesBackIn() throws {
    let fixture = try Fixture(samples: HALRenderSamplesInt32)
    fixture.write(bytes([Int32](repeating: 1000, count: 16)))
    #expect(renderInt32(fixture, frames: 2) == [1000, 1000])

    HALRenderSetSilenced(fixture.state, true)
    #expect(!HALRenderIsSilent(fixture.state))
    #expect(renderInt32(fixture, frames: 6) == [750, 500, 250, 0, 0, 0])
    #expect(HALRenderIsSilent(fixture.state))
    // Only the fade was taken, and the silence after it isn't an underrun.
    #expect(HALRenderConsumedBytes(fixture.state) == 6 * 4)
    #expect(renderInt32(fixture, frames: 2) == [0, 0])
    #expect(HALRenderConsumedBytes(fixture.state) == 6 * 4)
    #expect(HALRenderUnderrunBytes(fixture.state) == 0)

    HALRenderSetSilenced(fixture.state, false)
    #expect(!HALRenderIsSilent(fixture.state))
    #expect(renderInt32(fixture, frames: 6) == [250, 500, 750, 1000, 1000, 1000])
}

@Test func aPauseWithTooLittleQueuedEndsSilentAndStaysSo() throws {
    let fixture = try Fixture(samples: HALRenderSamplesInt32)
    fixture.write(bytes([Int32](repeating: 1000, count: 2)))
    _ = renderInt32(fixture, frames: 1)
    HALRenderSetSilenced(fixture.state, true)
    #expect(renderInt32(fixture, frames: 4) == [750, 0, 0, 0])
    #expect(HALRenderIsSilent(fixture.state))

    // Audio that arrives while paused waits for the play, which fades it in.
    fixture.write(bytes([Int32](repeating: 1000, count: 8)))
    #expect(renderInt32(fixture, frames: 4) == [0, 0, 0, 0])
    #expect(HALRenderConsumedBytes(fixture.state) == 2 * 4)
    HALRenderSetSilenced(fixture.state, false)
    #expect(renderInt32(fixture, frames: 5) == [250, 500, 750, 1000, 1000])
}

@Test func aPlayDuringAFadeOutTurnsBackFromWhereTheGainIs() throws {
    let fixture = try Fixture(samples: HALRenderSamplesInt32)
    fixture.write(bytes([Int32](repeating: 1000, count: 16)))
    HALRenderSetSilenced(fixture.state, true)
    #expect(renderInt32(fixture, frames: 2) == [750, 500])
    HALRenderSetSilenced(fixture.state, false)
    #expect(renderInt32(fixture, frames: 4) == [750, 1000, 1000, 1000])
}

@Test func isSilentAnswersOnlyTheLatestPause() throws {
    let fixture = try Fixture(samples: HALRenderSamplesInt32)
    fixture.write(bytes([Int32](repeating: 1000, count: 16)))
    HALRenderSetSilenced(fixture.state, true)
    _ = renderInt32(fixture, frames: 4)
    #expect(HALRenderIsSilent(fixture.state))
    HALRenderSetSilenced(fixture.state, false)
    HALRenderSetSilenced(fixture.state, true)
    // No cycle has run for this pause, and one may yet fade in before it.
    #expect(!HALRenderIsSilent(fixture.state))
    _ = renderInt32(fixture, frames: 2)
    #expect(HALRenderIsSilent(fixture.state))
}

@Test func aSeekFadesTheOldAudioOutThenTheNewIn() throws {
    let fixture = try Fixture(samples: HALRenderSamplesInt32)
    fixture.write(bytes([Int32](repeating: 1000, count: 8)))
    #expect(renderInt32(fixture, frames: 2) == [1000, 1000])

    HALRenderDiscard(fixture.state, 0, 8 * 4)
    fixture.write(bytes([Int32](repeating: 2000, count: 8)))
    #expect(
        renderInt32(fixture, frames: 10) == [750, 500, 250, 0, 500, 1000, 1500, 2000, 2000, 2000])
    // The four old frames faded out were taken; the two after them were skipped.
    #expect(HALRenderConsumedBytes(fixture.state) == (8 + 6) * 4)
    #expect(HALRenderUnderrunBytes(fixture.state) == 0)
}

@Test func aSeekDuringAFadeOutCarriesOnFromWhereTheGainIs() throws {
    let fixture = try Fixture(samples: HALRenderSamplesInt32)
    fixture.write(bytes([Int32](repeating: 1000, count: 5)))
    _ = renderInt32(fixture, frames: 1)
    HALRenderDiscard(fixture.state, 0, 5 * 4)
    fixture.write(bytes([Int32](repeating: 2000, count: 4)))
    #expect(renderInt32(fixture, frames: 2) == [750, 500])

    // A second seek before the first has faded out: the fade goes on, and the 2000s never play.
    HALRenderDiscard(fixture.state, 0, 9 * 4)
    fixture.write(bytes([Int32](repeating: 3000, count: 8)))
    #expect(renderInt32(fixture, frames: 7) == [250, 0, 750, 1500, 2250, 3000, 3000])
}

@Test func aSeekDuringAFadeInCarriesOnFromWhereTheGainIs() throws {
    let fixture = try Fixture(samples: HALRenderSamplesInt32)
    fixture.write(bytes([Int32](repeating: 1000, count: 5)))
    _ = renderInt32(fixture, frames: 1)
    HALRenderDiscard(fixture.state, 0, 5 * 4)
    fixture.write(bytes([Int32](repeating: 2000, count: 8)))
    #expect(renderInt32(fixture, frames: 6) == [750, 500, 250, 0, 500, 1000])

    // Halfway up, so the next fade-out takes two frames from half gain.
    HALRenderDiscard(fixture.state, 0, 13 * 4)
    fixture.write(bytes([Int32](repeating: 3000, count: 8)))
    #expect(renderInt32(fixture, frames: 7) == [500, 0, 750, 1500, 2250, 3000, 3000])
}

@Test func aSeekWithTooLittleQueuedFadesFromLower() throws {
    let fixture = try Fixture(samples: HALRenderSamplesInt32)
    fixture.write(bytes([Int32](repeating: 1000, count: 3)))
    _ = renderInt32(fixture, frames: 1)
    HALRenderDiscard(fixture.state, 0, 3 * 4)
    fixture.write(bytes([Int32](repeating: 2000, count: 6)))
    #expect(renderInt32(fixture, frames: 7) == [250, 0, 500, 1000, 1500, 2000, 2000])
}

@Test func aDiscardAheadForTheNextTrackDoesntFade() throws {
    let fixture = try Fixture(samples: HALRenderSamplesInt32)
    fixture.write(bytes([Int32](arrayLiteral: 1000, 1001, 1002, 5, 5)))
    #expect(renderInt32(fixture, frames: 1) == [1000])
    HALRenderDiscard(fixture.state, 3 * 4, 5 * 4)
    fixture.write(bytes([Int32](arrayLiteral: 7, 8)))
    #expect(renderInt32(fixture, frames: 4) == [1001, 1002, 7, 8])
}

@Test func aStartAfterAStopFadesInOnlyWhenAsked() throws {
    let fixture = try Fixture(samples: HALRenderSamplesInt32)
    fixture.write(bytes([Int32](repeating: 1000, count: 12)))
    HALRenderPrepareStart(fixture.state, true)
    #expect(renderInt32(fixture, frames: 5) == [250, 500, 750, 1000, 1000])
    HALRenderPrepareStart(fixture.state, false)
    #expect(renderInt32(fixture, frames: 2) == [1000, 1000])
}

@Test func aDiscardPostedWhileStoppedDropsWhatNeverPlayedAtOnce() throws {
    let fixture = try Fixture(samples: HALRenderSamplesInt32)
    fixture.write(bytes([Int32](repeating: 1000, count: 8)))
    _ = renderInt32(fixture, frames: 2)
    // Stopped, then a track loaded over what was queued, then started from its first frame.
    HALRenderDiscard(fixture.state, 0, 8 * 4)
    fixture.write(bytes([Int32](repeating: 2000, count: 4)))
    HALRenderPrepareStart(fixture.state, false)
    #expect(renderInt32(fixture, frames: 4) == [2000, 2000, 2000, 2000])
}

@Test func opaqueBytesNeverFadeAndAreSilentAtOnce() throws {
    let fixture = try Fixture()
    let frames: [UInt8] = [0, 0x69, 0x96, 0x05, 0, 0x69, 0x96, 0xFA]
    fixture.write(frames + frames)
    HALRenderPrepareStart(fixture.state, true)
    HALRenderSetSilenced(fixture.state, true)
    #expect(HALRenderIsSilent(fixture.state))
    #expect(render(fixture.state, bytes: 8) == frames)
    HALRenderDiscard(fixture.state, 0, 16)
    fixture.write(frames)
    #expect(render(fixture.state, bytes: 8) == frames)
}

/// `value`, from -1 to 1, as a sample of `kind`.
private func encode(_ value: Double, as kind: HALRenderSampleKind) -> [UInt8] {
    switch kind {
    case HALRenderSamplesInt16: return bytes([Int16((value * 32767).rounded())])
    case HALRenderSamplesInt24:
        let sample = Int32((value * 8_388_607).rounded())
        return [
            UInt8(truncatingIfNeeded: sample), UInt8(truncatingIfNeeded: sample >> 8),
            UInt8(truncatingIfNeeded: sample >> 16),
        ]
    case HALRenderSamplesInt32: return bytes([Int32((value * 2_147_483_647).rounded())])
    default: return bytes([Float(value)])
    }
}

/// The sample of `kind` in `raw`, from -1 to 1.
private func decode(_ raw: [UInt8], as kind: HALRenderSampleKind) -> Double {
    switch kind {
    case HALRenderSamplesInt16: return Double(values(raw, as: Int16.self)[0]) / 32767
    case HALRenderSamplesInt24:
        let high = UInt32(raw[0]) << 8 | UInt32(raw[1]) << 16 | UInt32(raw[2]) << 24
        return Double(Int32(bitPattern: high) >> 8) / 8_388_607
    case HALRenderSamplesInt32: return Double(values(raw, as: Int32.self)[0]) / 2_147_483_647
    default: return Double(values(raw, as: Float.self)[0])
    }
}

private let deviceKinds = [
    HALRenderSamplesInt16, HALRenderSamplesInt24, HALRenderSamplesInt32, HALRenderSamplesFloat32,
]

/// A stereo 997 Hz sine at 44.1 kHz, paused after three cycles of 256 frames and played again
/// after three more, checked against what the device received and the source frames the IO proc
/// took, as it played them.
@Test(arguments: deviceKinds)
func aSinePausedAndPlayedStepsNoMoreThanTheFadeAllowsAndIsUntouchedOutsideIt(
    _ kind: HALRenderSampleKind
) throws {
    let rate = 44_100.0
    let amplitude = 0.9
    let width = sampleBytes(kind)
    let frameBytes = 2 * width
    var source: [UInt8] = []
    for frame in 0..<4096 {
        for channel in 0..<2 {
            let phase: Double = 2 * .pi * 997 * Double(frame) / rate + Double(channel) * .pi / 2
            source += encode(amplitude * sin(phase), as: kind)
        }
    }
    let fixture = try Fixture(samples: kind, channels: 2, sampleRateHz: rate, capacity: 1 << 16)
    fixture.write(source)
    HALRenderPrepareStart(fixture.state, false)

    let cycle = 256
    var heard: [UInt8] = []
    var taken: [UInt8] = []
    var consumed: UInt64 = 0
    func play(cycles: Int) {
        for _ in 0..<cycles {
            let output = render(fixture.state, bytes: cycle * frameBytes)
            let now = HALRenderConsumedBytes(fixture.state)
            heard += output
            taken += output.prefix(Int(now - consumed))
            consumed = now
        }
    }
    play(cycles: 3)
    HALRenderSetSilenced(fixture.state, true)
    play(cycles: 3)
    #expect(HALRenderIsSilent(fixture.state))
    HALRenderSetSilenced(fixture.state, false)
    play(cycles: 9)
    #expect(HALRenderUnderrunBytes(fixture.state) == 0)

    // Every frame taken is the source's, untouched, but for the fade out and in either side of
    // where the pause was.
    let fade = Int(HALRenderFadeFrames(rate))
    let pausedAt = 3 * cycle
    let fades = pausedAt..<pausedAt + 2 * fade
    #expect(taken.count == (12 * cycle + fade) * frameBytes)
    var changed: [Int] = []
    for frame in 0..<taken.count / frameBytes {
        let range = frame * frameBytes..<(frame + 1) * frameBytes
        if taken[range] != source[range] { changed.append(frame) }
    }
    #expect(changed.allSatisfy(fades.contains), "changed outside the fades: \(changed)")
    #expect(changed.count > fade)

    // The sine's own steepest step, plus the most a step of the fade adds, plus rounding.
    let allowed = amplitude * 2 * .pi * 997 / rate + amplitude / Double(fade) + 1e-4
    var steepest = 0.0
    for channel in 0..<2 {
        var previous: Double?
        for frame in 0..<heard.count / frameBytes {
            let start = frame * frameBytes + channel * width
            let value = decode(Array(heard[start..<start + width]), as: kind)
            if let previous { steepest = max(steepest, abs(value - previous)) }
            previous = value
        }
    }
    #expect(steepest <= allowed, "steepest step \(steepest), allowed \(allowed)")
}
