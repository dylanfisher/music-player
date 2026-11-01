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
/// them different names.
public final class NullDevice: PCMDeviceProvider, @unchecked Sendable {
    public let deviceName: String
    public var deviceUID: String { deviceName }
    /// How many times faster than real time the IO proc runs.
    public let speed: Double
    public let ioFrames: Int
    private let keepsSamples: Bool
    private let lock = NSLock()
    private var connected = true
    private var watcher: (@Sendable () -> Void)?
    private var stateWatcher: (@Sendable (DeviceState) -> Void)?
    private var nominalSampleRateHz = 44_100.0
    private var otherHogOwner: Int32?
    private var volumes: [VolumeControl] = []
    private var formats = NullDevice.anyRate
    private var runs: [CapturedRun] = []
    private var restoredDefaults = 0
    private var openSessions = 0
    private var goesAwayDuring: (step: SessionStep, callsLeft: Int, afterSeconds: Double)?

    /// A call on a session the device can go away during.
    enum SessionStep: String, CaseIterable, Sendable {
        case stop, configure, start
    }

    /// What a session call throws when the device goes away during it.
    struct WentAway: Error, CustomStringConvertible {
        var step: SessionStep
        var description: String { "the null device went away during \(step.rawValue)" }
    }

    /// What the IO proc wrote while the device ran at one rate.
    public struct CapturedRun: Sendable {
        public var sampleRateHz: Double
        /// Interleaved stereo. Empty unless the device keeps samples.
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
        return .connected(
            DeviceSignal(
                nominalSampleRateHz: nominalSampleRateHz,
                physical: SignalFormat(Self.format(sampleRateHz: nominalSampleRateHz)),
                isMixable: false, hogMode: hog, volumes: volumes, formats: formats))
    }

    static func format(sampleRateHz: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRateHz, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonMixable,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
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
        lock.withLock { goesAwayDuring = (step, call, afterSeconds) }
    }

    fileprivate func perform(_ step: SessionStep) throws {
        let delay = lock.withLock { () -> Double? in
            guard let goes = goesAwayDuring, goes.step == step else { return nil }
            guard goes.callsLeft == 1 else {
                goesAwayDuring?.callsLeft -= 1
                return nil
            }
            goesAwayDuring = nil
            return goes.afterSeconds
        }
        guard let delay else { return }
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

    fileprivate func began(sampleRateHz: Double) {
        lock.withLock {
            nominalSampleRateHz = sampleRateHz
            runs.append(CapturedRun(sampleRateHz: sampleRateHz, samples: []))
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
        private var stopRequested: StopFlag?
        private var finished: DispatchSemaphore?
        private var isOpen = true

        init(_ device: NullDevice) { self.device = device }

        func configure(sampleRateHz: Double, channels: UInt32) throws -> DeviceFormat {
            precondition(channels == 2, "the null device is stereo")
            try device.perform(.configure)
            self.sampleRateHz = sampleRateHz
            device.began(sampleRateHz: sampleRateHz)
            let format = NullDevice.format(sampleRateHz: sampleRateHz)
            return DeviceFormat(
                stream: format,
                summary: "\(device.deviceName): \(PhysicalFormat(format).summary)",
                latencySeconds: Double(device.ioFrames) / sampleRateHz / device.speed)
        }

        func start(_ render: OpaquePointer) throws {
            precondition(stopRequested == nil, "the null device is already running")
            try device.perform(.start)
            let stop = StopFlag()
            let finished = DispatchSemaphore(value: 0)
            stopRequested = stop
            self.finished = finished
            let device = device
            let bytes = device.ioFrames * 8
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
