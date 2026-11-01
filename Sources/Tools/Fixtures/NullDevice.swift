import CoreAudio
import Foundation
import HALOutput
import HALRender

/// An output device that plays nothing: it runs `HALRenderIOProc` on its own thread, as CoreAudio
/// would, at real-time pace or faster, and can keep every sample it pulls. Tests and benchmarks
/// use it so playback never sounds on the build Mac. It reports a stereo 32-bit integer format at
/// any rate, like the owner's DAC, and can be unplugged and plugged back in.
public final class NullDevice: PCMDeviceProvider, @unchecked Sendable {
    public let deviceName = "null device"
    /// How many times faster than real time the IO proc runs.
    public let speed: Double
    public let ioFrames: Int
    private let keepsSamples: Bool
    private let lock = NSLock()
    private var connected = true
    private var watcher: (@Sendable () -> Void)?
    private var runs: [CapturedRun] = []
    private var restoredDefaults = 0
    private var openSessions = 0
    private var goesAwayDuring: (step: SessionStep, callsLeft: Int, afterSeconds: Double)?

    /// A call on a session the device can go away during.
    public enum SessionStep: String, CaseIterable, Sendable {
        case stop, configure, start
    }

    /// What a session call throws when the device goes away during it.
    public struct WentAway: Error, CustomStringConvertible {
        public var step: SessionStep
        public var description: String { "the null device went away during \(step.rawValue)" }
    }

    /// What the IO proc wrote while the device ran at one rate.
    public struct CapturedRun: Sendable {
        public var sampleRateHz: Double
        /// Interleaved stereo. Empty unless the device keeps samples.
        public var samples: [Int32]
    }

    public init(speed: Double = 1, ioFrames: Int = 512, keepsSamples: Bool = false) {
        precondition(speed > 0, "speed must be positive")
        self.speed = speed
        self.ioFrames = ioFrames
        self.keepsSamples = keepsSamples
    }

    /// One run per `configure`, in order.
    public var captured: [CapturedRun] { lock.withLock { runs } }
    /// How many sessions are open; zero once every one has been closed or abandoned.
    public var openSessionCount: Int { lock.withLock { openSessions } }
    public var defaultsRestoredCount: Int { lock.withLock { restoredDefaults } }

    public func unplug() { setConnected(false) }
    public func plugIn() { setConnected(true) }
    /// Connects the device without telling the watcher, as when a change notification is missed.
    public func plugInUnannounced() { lock.withLock { connected = true } }

    /// Makes the device go away during the `call`th call of `step` from now, counting every
    /// session's, as a DAC unplugged mid-switch does: the call fails, and the device reads as
    /// gone and the watcher is told, at once or `afterSeconds` after the call fails, as the HAL
    /// may report it later. Counting calls lets a test arm it before playing, so it never
    /// depends on when an event reaches the test.
    public func goAway(during step: SessionStep, call: Int = 1, afterSeconds: Double = 0) {
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
    }

    public func open() throws -> (any PCMDevice)? {
        lock.withLock {
            guard connected else { return nil }
            openSessions += 1
            return Session(self)
        }
    }

    public func isConnected() -> Bool { lock.withLock { connected } }
    public func watch(_ changed: @escaping @Sendable () -> Void) throws {
        lock.withLock { watcher = changed }
    }
    public func stopWatching() { lock.withLock { watcher = nil } }
    public func deviceReturned() { lock.withLock { restoredDefaults += 1 } }

    fileprivate func began(sampleRateHz: Double) {
        lock.withLock {
            runs.append(CapturedRun(sampleRateHz: sampleRateHz, samples: []))
        }
    }

    fileprivate func pulled(_ buffer: UnsafeRawBufferPointer) {
        guard keepsSamples else { return }
        lock.withLock { runs[runs.count - 1].samples += buffer.bindMemory(to: Int32.self) }
    }

    fileprivate func ended() { lock.withLock { openSessions -= 1 } }

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
            let format = AudioStreamBasicDescription(
                mSampleRate: sampleRateHz, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
                    | kAudioFormatFlagIsNonMixable,
                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                mBitsPerChannel: 32, mReserved: 0)
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
            let cycleSeconds = Double(device.ioFrames) / sampleRateHz / device.speed
            // The pointer crosses to the IO thread the way CoreAudio's client data would.
            let renderAddress = UInt(bitPattern: render)
            let thread = Thread {
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
                defer { buffer.deallocate() }
                var time = AudioTimeStamp()
                var input = AudioBufferList()
                var deadline = ProcessInfo.processInfo.systemUptime
                while !stop.isSet {
                    var list = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: 2, mDataByteSize: UInt32(bytes), mData: buffer))
                    _ = HALRenderIOProc(
                        0, &time, &input, &time, &list, &time,
                        UnsafeMutableRawPointer(bitPattern: renderAddress))
                    device.pulled(UnsafeRawBufferPointer(start: buffer, count: bytes))
                    deadline += cycleSeconds
                    let wait = deadline - ProcessInfo.processInfo.systemUptime
                    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
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
