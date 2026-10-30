import AppKit
import HALOutput

// `MusicPlayer --list-devices` prints what each output device supports, then exits. It's run
// from Terminal on the Mac the DAC is attached to.
if CommandLine.arguments.contains("--list-devices") {
    do {
        print(deviceReport(try AudioDevice.outputDevices()))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
