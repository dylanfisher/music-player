import Commands
import Foundation
import Settings

let settingsBenchmarks = [
    Benchmark(
        name: "settings: load and validate, every key changed",
        budget: Budget(appleSilicon: 5, oldMac: 20, unit: .milliseconds)
    ) {
        try withScratchDirectory("settings") { directory in
            let url = directory.appendingPathComponent("config.json")
            let bindings = try KeyBindings(
                AppCommands.all(), overrides: [:], rules: AppMenus.rules(appName: "Bench"))
            let check: ShortcutCheck = { bindings.problem(id: $0, position: $1, slot: $2) }
            return try MainActor.assumeIsolated {
                let settings = ConfigStore(
                    AppSettings(), fileURL: url, check: check, creating: true)
                try settings.set(\.outputDeviceUID, to: "AppleUSBAudioEngine:RME:ADI-2 DAC:1")
                try settings.set(\.hogMode, to: false)
                try settings.set(\.digitalVolume, to: true)
                try settings.set(\.pausePollingDuringPlayback, to: true)
                try settings.set(\.networkScanReaders, to: 16)
                try settings.set(\.appearance, to: .dark)
                try settings.set(
                    \.watchedFolders,
                    to: (0..<20).map { index in
                        WatchedFolder(
                            path: "/Volumes/Music/Share \(index)", kind: .network,
                            include: ["*.flac", "*.m4a"], exclude: ["**/Scans/**"])
                    })
                for command in AppCommands.all().prefix(20) {
                    settings.setShortcut(
                        command.id.rawValue, to: ShortcutOverride(alternate: .removed))
                }
                guard settings.problems.isEmpty, settings.writeFailure == nil else {
                    throw BenchError.expected("a config file the store wrote to read back cleanly")
                }
                return Measured(
                    value: try medianMilliseconds(iterations: 200) {
                        _ = try ConfigStore.strict(AppSettings(), fileURL: url, check: check)
                    })
            }
        }
    }
]
