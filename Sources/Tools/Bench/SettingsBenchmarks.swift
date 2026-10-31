import Foundation
import Settings

let settingsBenchmarks = [
    Benchmark(
        name: "settings: load and validate, every key changed",
        budget: Budget(appleSilicon: 5, oldMac: 20, unit: .milliseconds)
    ) {
        try withScratchDirectory("settings") { directory in
            let url = directory.appendingPathComponent("settings.json")
            let settings = try SettingsStore(AppSettings(), fileURL: url)
            try settings.set(\.outputDeviceUID, to: "AppleUSBAudioEngine:RME:ADI-2 DAC:1")
            try settings.set(\.hogMode, to: false)
            try settings.set(\.pausePollingDuringPlayback, to: true)
            try settings.set(\.networkScanReaders, to: 16)
            try settings.set(
                \.watchedFolders,
                to: (0..<20).map { index in
                    WatchedFolder(
                        path: "/Volumes/Music/Share \(index)", kind: .network,
                        include: ["*.flac", "*.m4a"], exclude: ["**/Scans/**"])
                })
            return Measured(
                value: try medianMilliseconds(iterations: 200) {
                    _ = try SettingsStore(AppSettings(), fileURL: url)
                })
        }
    }
]
