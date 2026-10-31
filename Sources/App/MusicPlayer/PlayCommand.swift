import DisplayText
import Foundation
import HALOutput
import Playback
import Settings

enum PlayCommandError: Error, CustomStringConvertible {
    case missing(String)
    case unlistable(String)
    case nothingToPlay
    case noDevice(named: String, available: [String])

    var description: String {
        switch self {
        case .missing(let path): "\(path) doesn't exist"
        case .unlistable(let path): "can't list \(path)"
        case .nothingToPlay: "--play needs at least one audio file or folder"
        case .noDevice(let name, let available):
            "no output device matches \"\(name)\". Devices: \(available.joined(separator: ", "))"
        }
    }
}

/// How far a seek key moves, in the terminal and the window.
let seekStepSeconds = 10.0
/// How much a volume key changes the digital volume.
let volumeStepDecibels = 3.0

/// What the keys do, printed when playback starts.
private let keyHelp =
    "keys: space pause/resume, n next, p previous, ←/→ seek 10 s, r repeat, s shuffle,"
    + " -/+ volume, q quit"

/// `MusicPlayer --play <file or folder>... [--device <part of name>]`: plays the files as a queue,
/// bit-perfect, on the device from `--device` or Settings, with keyboard control. Restores the
/// device, the default outputs and the terminal on q, Ctrl-C, SIGTERM, an error, or the end of the
/// queue. Never returns.
@MainActor
func playCommand(paths: [String], deviceName: String?) throws -> Never {
    guard !paths.isEmpty else { throw PlayCommandError.nothingToPlay }
    let appFiles = try appPaths()
    let settings = try readConfig(appFiles)
    let recordURL = restoreRecordURL(in: appFiles.dataDirectory)
    if let recovered = try HALDeviceProvider.recoverAfterCrash(restoreRecordURL: recordURL) {
        print(recovered)
    }

    // Printed first, because reading a network folder can block on a privacy prompt.
    print("reading \(paths.joined(separator: ", "))")
    fflush(stdout)
    let (files, warnings) = try queuedFiles(paths)
    for warning in warnings { print("warning: \(warning)") }
    guard !files.isEmpty else { throw PlayCommandError.nothingToPlay }

    let deviceUID = try deviceName.map(uid(ofDeviceNamed:)) ?? settings[\.outputDeviceUID]
    let provider = try HALDeviceProvider(
        deviceUID: deviceUID, hogMode: settings[\.hogMode], restoreRecordURL: recordURL)
    let output = try DeviceOutput(provider: provider, digitalVolume: settings[\.digitalVolume])
    let player = Player(engine: PlaybackEngine(output: output), output: output, files: files)
    print("\(files.count) tracks on \(provider.deviceName)")
    if try enterKeyMode() { print(keyHelp) }
    player.start()
    dispatchMain()
}

private func uid(ofDeviceNamed name: String) throws -> String {
    let devices = try AudioDevice.outputDevices()
    guard let match = devices.first(where: { $0.name.localizedCaseInsensitiveContains(name) })
    else { throw PlayCommandError.noDevice(named: name, available: devices.map(\.name)) }
    return match.uid
}

/// Runs the queue: prints what happens, turns keys into engine calls, and quits once.
private final class Player: @unchecked Sendable {
    private let engine: PlaybackEngine
    private let output: DeviceOutput
    private let files: [QueuedFile]
    private let lock = NSLock()
    private var quitting = false
    private var signals: [DispatchSourceSignal] = []
    /// The digital volume, in dB below full.
    private var volumeDecibels = 0.0

    init(engine: PlaybackEngine, output: DeviceOutput, files: [QueuedFile]) {
        self.engine = engine
        self.output = output
        self.files = files
    }

    func start() {
        let (keys, pressed) = AsyncStream.makeStream(of: Key.self)
        signals = [SIGINT, SIGTERM, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            // The first stops playback so the device gets restored; a second quits at once, in
            // case restoring hangs.
            source.setEventHandler { [self] in
                if beginQuitting() { finish(status: 0) } else { exit(128 + number) }
            }
            source.resume()
            return source
        }
        // Ctrl-Z: hand the terminal back to the shell before stopping, and take it again on fg.
        // Playback stops with the process, so the device plays silence meanwhile.
        signals += [SIGTSTP, SIGCONT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                if number == SIGTSTP {
                    restoreTerminal()
                    kill(getpid(), SIGSTOP)
                } else {
                    resumeKeyMode()
                }
            }
            source.resume()
            return source
        }
        Thread.detachNewThread { readKeys { pressed.yield($0) } }
        let engine = engine
        let files = files
        Task.detached { [self] in
            let updates = await engine.updates()
            await engine.setQueue(files.map(\.url))
            await engine.play()
            for await update in updates { show(update) }
        }
        // One task runs the keys, so they reach the engine in the order they were pressed.
        Task.detached { [self] in
            for await key in keys { await press(key) }
        }
        Task.detached {
            while true {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    return  // only cancellation throws, and nothing cancels this
                }
                let state = await engine.state
                guard state.status != .stopped, let position = await engine.position() else {
                    continue
                }
                let duration = state.durationSeconds.map(clock) ?? "?"
                print("\r  \(clock(position)) / \(duration)", terminator: "")
                fflush(stdout)
            }
        }
    }

    private func press(_ key: Key) async {
        switch key {
        case .space: await engine.togglePause()
        case .next: await engine.next()
        case .previous: await engine.previous()
        case .forward, .back:
            let step = key == .forward ? seekStepSeconds : -seekStepSeconds
            if let position = await engine.position() {
                await engine.seek(toSeconds: position + step)
            }
        case .repeatMode:
            let modes = RepeatMode.allCases
            let now = await engine.state.repeatMode
            await engine.setRepeat(modes[(modes.firstIndex(of: now)! + 1) % modes.count])
        case .shuffle: await engine.setShuffle(!(await engine.state.shuffle))
        case .volumeDown, .volumeUp:
            let step = key == .volumeUp ? volumeStepDecibels : -volumeStepDecibels
            let decibels = min(0, volumeDecibels + step)
            do {
                try await engine.setVolume(pow(10, decibels / 20))
                volumeDecibels = decibels
                log(decibels == 0 ? "volume: full, bit-perfect" : "volume: \(Int(decibels)) dB")
            } catch {
                log("\(error); the output.digitalVolume setting turns it on")
            }
        case .quit:
            if beginQuitting() { finish(status: 0) }
        }
    }

    private func show(_ update: PlaybackUpdate) {
        let state = update.state
        switch update.event {
        case .trackStarted(let index):
            let file = files[index]
            let source = file.format.map { " (\($0))" } ?? ""
            log(
                "▶ \(index + 1)/\(files.count) \(file.name)\(source)"
                    + " → \(state.outputFormat ?? "?")")
        case .formatChanged(let change):
            if let from = change.from, from != change.to {
                func ms(_ seconds: Double) -> String { String(Int((seconds * 1000).rounded())) }
                let steps = change.steps.map { steps in
                    " (" + steps.map { "\($0.name) \(ms($0.seconds))" }.joined(separator: ", ")
                        + ")"
                }
                let took = change.switchSeconds.map { " in \(ms($0)) ms\(steps ?? "")" } ?? ""
                log("rate change: \(from) → \(change.to)\(took)")
            }
        case .trackFailed(let url, let reason): log("✗ couldn't play \(url.path): \(reason)")
        case .underrun(let frames): log("! underrun: \(frames) frames of silence")
        case .deviceLost:
            log("device lost: paused. Plug it back in, then press space to resume.")
        case .deviceReturned: log("device is back: press space to resume")
        case .paused: log("paused")
        case .resumed: log("playing")
        case .repeatChanged: log("repeat: \(state.repeatMode.rawValue)")
        case .shuffleChanged: log("shuffle: \(state.shuffle ? "on" : "off")")
        case .failed(let reason):
            log("error: \(reason)")
            if beginQuitting() { finish(status: 1) }
        case .finished, .stopped:
            log(update.event == .finished ? "done" : "stopped")
            if beginQuitting() { finish(status: 0) }
        case .queueChanged, .trackEnded, .seeked, nil: break
        }
    }

    /// True for the first caller only.
    private func beginQuitting() -> Bool {
        lock.withLock {
            defer { quitting = true }
            return !quitting
        }
    }

    /// Restores the device and the default outputs, then the terminal, then exits.
    private func finish(status: Int32) {
        Thread.detachNewThread { [output] in
            output.close()
            restoreTerminal()
            print(eraseLine + "restored the output device")
            exit(status)
        }
    }

    /// Progress rewrites one line in place, so log lines clear it first.
    private func log(_ line: String) {
        print(eraseLine + line)
        fflush(stdout)
    }
}
