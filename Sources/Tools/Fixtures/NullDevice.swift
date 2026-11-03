import CoreAudio
import Foundation
import HALOutput
import HALRender
import Playback

/// An output device that plays nothing: it runs `HALRenderIOProc` on its own thread, as CoreAudio
/// would, at real-time pace or faster, and can keep every sample it pulls. Tests and benchmarks
/// use it so playback never sounds on the build Mac. It reports a stereo 32-bit integer format at
/// any rate, like the owner's DAC, and can be unplugged and plugged back in. Tests can change its
/// rate, hog mode and volume as another app would, and it reports its state as the HAL's
/// listeners would. Tests can also narrow the rates and formats it reports, and give two of
/// them different names. A session takes a format from what it reports, as a CoreAudio device
/// does, converting when none carries the track.
public final class NullDevice: PCMDeviceProvider, @unchecked Sendable {
    public let deviceName: String
    public var deviceUID: String { deviceName }
    /// Set as the hog mode setting would be; off makes DSD refused.
    public var usesHogMode: Bool { lock.withLock { hogModeSetting } }
    private var hogModeSetting = true
    /// How many times faster than real time the IO proc runs.
    public let speed: Double
    public let ioFrames: Int
    private let keepsSamples: Bool
    private let lock = NSLock()
    private var connected = true
    private var watcher: (@Sendable () -> Void)?
    private var stateWatcher: (@Sendable (DeviceState) -> Void)?
    private var nominalSampleRateHz = 44_100.0
    /// What the last session configured, which its state reports at the nominal rate.
    private var physicalFormat = NullDevice.format(sampleRateHz: 44_100)
    private var otherHogOwner: Int32?
    private var volumes: [VolumeControl] = []
    private var formats = NullDevice.anyRate
    private var runs: [CapturedRun] = []
    private var restoredDefaults = 0
    private var openSessions = 0
    /// `goneAfterSeconds` is nil for a call that fails while the device stays.
    private var failsDuring: (step: SessionStep, callsLeft: Int, goneAfterSeconds: Double?)?

    /// A call on a session the device can go away during, or refuse.
    enum SessionStep: String, CaseIterable, Sendable {
        case stop, configure, start
    }

    /// What a session call throws when the device goes away during it.
    struct WentAway: Error, CustomStringConvertible {
        var step: SessionStep
        var description: String { "the null device went away during \(step.rawValue)" }
    }

    /// What a session call throws when the device refuses it and stays connected.
    struct Refused: Error, CustomStringConvertible {
        var step: SessionStep
        var description: String { "the null device refused \(step.rawValue)" }
    }

    /// What the IO proc wrote while the device ran at one rate.
    public struct CapturedRun: Sendable {
        public var sampleRateHz: Double
        /// Interleaved stereo, a float format's as their bits. Empty unless the device keeps
        /// samples.
        public var samples: [Int32]
    }

    public init(
        name: String = "null device", speed: Double = 1, ioFrames: Int = 512,
        keepsSamples: Bool = false
    ) {
        precondition(speed > 0, "speed must be positive")
        deviceName = name
        self.speed = speed
        self.ioFrames = ioFrames
        self.keepsSamples = keepsSamples
    }

    /// One run per `configure`, in order.
    public var captured: [CapturedRun] { lock.withLock { runs } }
    /// How many sessions are open; zero once every one has been closed or abandoned.
    var openSessionCount: Int { lock.withLock { openSessions } }
    var defaultsRestoredCount: Int { lock.withLock { restoredDefaults } }

    /// Whether a watcher is registered, which closing the output must undo.
    var isWatched: Bool { lock.withLock { watcher != nil || stateWatcher != nil } }

    func unplug() { setConnected(false) }

    /// Another app setting the device's rate, as in Audio MIDI Setup.
    func changeRate(to hertz: Double) {
        lock.withLock { nominalSampleRateHz = hertz }
        reportState()
    }

    /// The owner turning hog mode off for this device, or back on.
    func setHogModeSetting(_ on: Bool) { lock.withLock { hogModeSetting = on } }

    /// Another process taking exclusive access, or nil to give it back.
    func hogMode(heldBy pid: Int32?) {
        lock.withLock { otherHogOwner = pid }
        reportState()
    }

    func setVolumes(_ controls: [VolumeControl]) {
        lock.withLock { volumes = controls }
        reportState()
    }

    /// The device reporting other rates and formats, as one does when its listeners fire.
    func report(_ formats: DeviceFormats) {
        lock.withLock { self.formats = formats }
        reportState()
    }

    /// What Bluetooth AirPods offer on macOS 12: stereo 32-bit float at 48 kHz, mixable.
    static let float48k = DeviceFormats(
        sampleRatesHz: [48_000...48_000],
        formats: [
            PhysicalFormat(
                formatID: linearPCMFormatID, sampleRateHz: 48_000...48_000, bitsPerChannel: 32,
                channels: 2, isFloat: true, isMixable: true)
        ])

    /// Stereo 32-bit integer at any rate up to 768 kHz.
    static let anyRate = DeviceFormats(
        sampleRatesHz: [8_000...768_000],
        formats: [
            PhysicalFormat(
                AudioStreamRangedDescription(
                    mFormat: format(sampleRateHz: 8_000),
                    mSampleRateRange: AudioValueRange(mMinimum: 8_000, mMaximum: 768_000)))
        ])

    private func reportState() {
        let (watcher, state) = lock.withLock { (stateWatcher, state) }
        watcher?(state)
    }

    /// Called with the lock held.
    private var state: DeviceState {
        guard connected else { return .notConnected }
        let hog: HogMode =
            otherHogOwner.map { .otherProcess(pid: $0) }
            ?? (openSessions > 0 ? .thisProcess : .free)
        var physical = physicalFormat
        physical.mSampleRate = nominalSampleRateHz
        return .connected(
            DeviceSignal(
                nominalSampleRateHz: nominalSampleRateHz, physical: SignalFormat(physical),
                isMixable: PhysicalFormat(physical).isMixable, hogMode: hog, volumes: volumes,
                formats: formats))
    }

    static func format(sampleRateHz: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRateHz, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonMixable,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
    }
    /// `format` at `sampleRateHz`, packed and interleaved.
    static func format(_ format: PhysicalFormat, at sampleRateHz: Double)
        -> AudioStreamBasicDescription
    {
        let bytes = format.bitsPerChannel / 8 * format.channels
        var flags =
            (format.isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger)
            | kAudioFormatFlagIsPacked
        if !format.isMixable { flags |= kAudioFormatFlagIsNonMixable }
        return AudioStreamBasicDescription(
            mSampleRate: sampleRateHz, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
            mChannelsPerFrame: format.channels, mBitsPerChannel: format.bitsPerChannel,
            mReserved: 0)
    }

    /// What a session throws when no format it reports can take a track, even converted.
    struct NoFormat: Error, CustomStringConvertible {
        var description: String { "the null device has no PCM format to convert to" }
    }

    func plugIn() { setConnected(true) }
    /// Connects the device without telling the watcher, as when a change notification is missed.
    func plugInUnannounced() { lock.withLock { connected = true } }

    /// Makes the device go away during the `call`th call of `step` from now, counting every
    /// session's, as a DAC unplugged mid-switch does: the call fails, and the device reads as
    /// gone and the watcher is told, at once or `afterSeconds` after the call fails, as the HAL
    /// may report it later. Counting calls lets a test arm it before playing, so it never
    /// depends on when an event reaches the test.
    func goAway(during step: SessionStep, call: Int = 1, afterSeconds: Double = 0) {
        precondition(call >= 1, "calls count from 1")
        lock.withLock { failsDuring = (step, call, afterSeconds) }
    }

    /// Makes the `call`th call of `step` from now fail while the device stays connected, as a
    /// device that won't take a setting does.
    func refuse(_ step: SessionStep, call: Int = 1) {
        precondition(call >= 1, "calls count from 1")
        lock.withLock { failsDuring = (step, call, nil) }
    }

    fileprivate func perform(_ step: SessionStep) throws {
        // Nil when this call doesn't fail; then nil inside when the device stays.
        let failure = lock.withLock { () -> Double?? in
            guard let fails = failsDuring, fails.step == step else { return nil }
            guard fails.callsLeft == 1 else {
                failsDuring?.callsLeft -= 1
                return nil
            }
            failsDuring = nil
            return .some(fails.goneAfterSeconds)
        }
        guard let failure else { return }
        guard let delay = failure else { throw Refused(step: step) }
        if delay == 0 {
            unplug()
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in unplug() }
        }
        throw WentAway(step: step)
    }

    private func setConnected(_ connected: Bool) {
        let watcher = lock.withLock {
            self.connected = connected
            return self.watcher
        }
        watcher?()
        reportState()
    }

    public func open() throws -> (any PCMDevice)? {
        let session = lock.withLock { () -> Session? in
            guard connected else { return nil }
            openSessions += 1
            return Session(self)
        }
        if session != nil { reportState() }
        return session
    }

    public func isConnected() -> Bool { lock.withLock { connected } }
    public func watch(
        _ changed: @escaping @Sendable () -> Void,
        state: @escaping @Sendable (DeviceState) -> Void
    ) throws {
        lock.withLock {
            watcher = changed
            stateWatcher = state
        }
        reportState()
    }
    public func stopWatching() {
        lock.withLock {
            watcher = nil
            stateWatcher = nil
        }
    }
    public func deviceReturned() { lock.withLock { restoredDefaults += 1 } }

    fileprivate func began(_ format: AudioStreamBasicDescription) {
        lock.withLock {
            nominalSampleRateHz = format.mSampleRate
            physicalFormat = format
            runs.append(CapturedRun(sampleRateHz: format.mSampleRate, samples: []))
        }
        reportState()
    }

    fileprivate func pulled(_ buffer: UnsafeRawBufferPointer) {
        guard keepsSamples else { return }
        lock.withLock { runs[runs.count - 1].samples += buffer.bindMemory(to: Int32.self) }
    }

    fileprivate func ended() {
        lock.withLock { openSessions -= 1 }
        reportState()
    }

    private final class Session: PCMDevice {
        private let device: NullDevice
        private var sampleRateHz = 0.0
        private var bytesPerFrame = 0
        private var stopRequested: StopFlag?
        private var finished: DispatchSemaphore?
        private var isOpen = true

        init(_ device: NullDevice) { self.device = device }

        /// 32-bit and non-mixable, so it carries DoP, when the formats it reports take the track;
        /// otherwise the one `convertedFormat` picks from them.
        func configure(sampleRateHz: Double, channels: UInt32, forDoP: Bool) throws
            -> DeviceFormat
        {
            try device.perform(.configure)
            let (formats, allowNonMixable) = device.lock.withLock {
                (device.formats, device.hogModeSetting)
            }
            let format: AudioStreamBasicDescription
            let isConverted =
                !forDoP && !formats.takes(sampleRateHz: sampleRateHz, channels: channels)
            if isConverted {
                guard
                    let target = convertedFormat(
                        in: formats.formats, sampleRateHz: sampleRateHz, channels: channels,
                        allowNonMixable: allowNonMixable)
                else { throw NoFormat() }
                format = NullDevice.format(formats.formats[target.index], at: target.sampleRateHz)
            } else {
                format = NullDevice.format(sampleRateHz: sampleRateHz)
            }
            precondition(format.mChannelsPerFrame == 2, "the null device is stereo")
            self.sampleRateHz = format.mSampleRate
            bytesPerFrame = Int(format.mBytesPerFrame)
            device.began(format)
            return DeviceFormat(
                stream: format,
                summary: "\(device.deviceName): \(PhysicalFormat(format).summary)",
                latencySeconds: Double(device.ioFrames) / format.mSampleRate / device.speed,
                isConverted: isConverted)
        }

        func start(_ render: OpaquePointer) throws {
            precondition(stopRequested == nil, "the null device is already running")
            try device.perform(.start)
            let stop = StopFlag()
            let finished = DispatchSemaphore(value: 0)
            stopRequested = stop
            self.finished = finished
            let device = device
            let bytes = device.ioFrames * bytesPerFrame
            var timebase = mach_timebase_info()
            mach_timebase_info(&timebase)
            let cycleTicks =
                Double(device.ioFrames) / sampleRateHz / device.speed * 1e9
                * Double(timebase.denom) / Double(timebase.numer)
            // The pointer crosses to the IO thread the way CoreAudio's client data would.
            let renderAddress = UInt(bitPattern: render)
            let thread = Thread {
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
                defer { buffer.deallocate() }
                var time = AudioTimeStamp()
                var input = AudioBufferList()
                // Paced on the clock CoreAudio's IO thread waits on, so the playback benchmark
                // counts the wakeups a device costs and not Foundation's sleep on top of them.
                let start = Double(mach_absolute_time())
                var cycles = 0.0
                while !stop.isSet {
                    var list = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: 2, mDataByteSize: UInt32(bytes), mData: buffer))
                    _ = HALRenderIOProc(
                        0, &time, &input, &time, &list, &time,
                        UnsafeMutableRawPointer(bitPattern: renderAddress))
                    device.pulled(UnsafeRawBufferPointer(start: buffer, count: bytes))
                    cycles += 1
                    let deadline = UInt64(start + cycles * cycleTicks)
                    if deadline > mach_absolute_time() { mach_wait_until(deadline) }
                }
                finished.signal()
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        func stop() throws {
            guard let stopRequested, let finished else { return }
            // A real device that's gone stops calling the IO proc, whatever the call returns.
            defer {
                stopRequested.set()
                finished.wait()
                self.stopRequested = nil
                self.finished = nil
            }
            try device.perform(.stop)
        }

        func close() throws {
            try stop()
            end()
        }

        func abandon() -> Bool {
            // Stopping the null device can't fail.
            try! stop()
            end()
            return true
        }

        private func end() {
            guard isOpen else { return }
            isOpen = false
            device.ended()
        }
    }
}

/// A flag one thread sets and another polls.
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
