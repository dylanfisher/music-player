// swift-tools-version: 6.2

import PackageDescription

// Every target lives at Sources/<Tier>/<Name>; scripts/arch.swift reads the tier from that path
// and enforces the dependency direction in docs/map.md.
let strictSwift: [SwiftSetting] = [.treatAllWarnings(as: .error)]
let strictC: [CSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "MusicPlayer",
    // The 2015 MacBook Pro tops out at macOS 12.
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "RingBuffer",
            path: "Sources/Primitives/RingBuffer",
            cSettings: strictC
        ),
        .target(
            name: "DisplayText",
            path: "Sources/Primitives/DisplayText",
            swiftSettings: strictSwift
        ),
        .target(
            name: "SQLite",
            path: "Sources/Primitives/SQLite",
            swiftSettings: strictSwift,
            // The system library, through the SDK's SQLite3 module.
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "HALRender",
            dependencies: ["RingBuffer"],
            path: "Sources/Core/HALRender",
            cSettings: strictC
        ),
        .target(
            name: "Log",
            path: "Sources/Core/Log",
            swiftSettings: strictSwift
        ),
        .target(
            name: "HALOutput",
            dependencies: ["DisplayText", "HALRender", "Log", "Playback", "RingBuffer"],
            path: "Sources/Core/HALOutput",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Playback",
            dependencies: ["Log"],
            path: "Sources/Core/Playback",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Metadata",
            path: "Sources/Core/Metadata",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Library",
            dependencies: ["Log", "Metadata", "Settings", "SQLite"],
            path: "Sources/Core/Library",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Artwork",
            dependencies: ["Metadata"],
            path: "Sources/Core/Artwork",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Settings",
            dependencies: ["Log"],
            path: "Sources/Core/Settings",
            swiftSettings: strictSwift
        ),
        .target(
            name: "LibraryBrowser",
            dependencies: ["DisplayText", "Library", "Log", "Settings"],
            path: "Sources/Features/LibraryBrowser",
            swiftSettings: strictSwift
        ),
        .target(
            name: "NowPlaying",
            dependencies: ["Artwork", "DisplayText", "Library", "Log", "Playback"],
            path: "Sources/Features/NowPlaying",
            swiftSettings: strictSwift
        ),
        .target(
            name: "QueueView",
            dependencies: ["DisplayText", "Library", "Log", "Playback"],
            path: "Sources/Features/QueueView",
            swiftSettings: strictSwift
        ),
        .executableTarget(
            name: "MusicPlayer",
            dependencies: [
                "Artwork", "DisplayText", "HALOutput", "Library", "LibraryBrowser", "Log",
                "Metadata", "NowPlaying", "Playback", "QueueView", "SQLite", "Settings",
            ],
            path: "Sources/App/MusicPlayer",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Fixtures",
            dependencies: ["HALOutput", "HALRender", "Library", "Log", "Metadata"],
            path: "Sources/Tools/Fixtures",
            swiftSettings: strictSwift
        ),
        .executableTarget(
            name: "GenerateFixtures",
            dependencies: ["Fixtures"],
            path: "Sources/Tools/GenerateFixtures",
            swiftSettings: strictSwift
        ),
        .executableTarget(
            name: "Bench",
            dependencies: [
                "DisplayText", "Fixtures", "HALOutput", "Library", "LibraryBrowser", "Metadata",
                "Playback", "SQLite", "Settings",
            ],
            path: "Sources/Tools/Bench",
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "ArtworkTests",
            dependencies: ["Artwork", "Metadata"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "BenchTests",
            dependencies: ["Bench"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "DisplayTextTests",
            dependencies: ["DisplayText"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "FixturesTests",
            dependencies: ["Fixtures"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "HALOutputTests",
            dependencies: ["Fixtures", "HALOutput", "Playback"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "HALRenderTests",
            dependencies: ["HALRender", "RingBuffer"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "LibraryTests",
            dependencies: ["Fixtures", "Library", "Metadata", "Settings", "SQLite"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "LibraryBrowserTests",
            dependencies: ["Fixtures", "Library", "LibraryBrowser", "SQLite", "Settings"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "LogTests",
            dependencies: ["Log"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "MetadataTests",
            dependencies: ["Fixtures", "Metadata"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "MusicPlayerTests",
            dependencies: ["Library", "Metadata", "MusicPlayer", "Playback"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "NowPlayingTests",
            dependencies: ["Library", "Metadata", "NowPlaying", "Playback"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "PlaybackTests",
            dependencies: ["Playback"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "QueueViewTests",
            dependencies: ["Library", "Playback", "QueueView"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "SettingsTests",
            dependencies: ["Settings"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "SQLiteTests",
            dependencies: ["SQLite"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "RingBufferTests",
            dependencies: ["RingBuffer"],
            swiftSettings: strictSwift
        ),
    ],
    swiftLanguageModes: [.v6]
)
