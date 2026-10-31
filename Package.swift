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
            dependencies: ["HALRender", "Log"],
            path: "Sources/Core/HALOutput",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Playback",
            dependencies: ["HALOutput", "Log", "RingBuffer"],
            path: "Sources/Core/Playback",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Metadata",
            path: "Sources/Core/Metadata",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Settings",
            dependencies: ["Log"],
            path: "Sources/Core/Settings",
            swiftSettings: strictSwift
        ),
        .executableTarget(
            name: "MusicPlayer",
            dependencies: ["HALOutput", "Playback", "Settings"],
            path: "Sources/App/MusicPlayer",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Fixtures",
            dependencies: ["Log", "Metadata"],
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
            dependencies: ["Fixtures", "Metadata", "Settings"],
            path: "Sources/Tools/Bench",
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "BenchTests",
            dependencies: ["Bench"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "FixturesTests",
            dependencies: ["Fixtures"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "HALOutputTests",
            dependencies: ["HALOutput"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "HALRenderTests",
            dependencies: ["HALRender", "RingBuffer"],
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
            name: "PlaybackTests",
            dependencies: ["Playback"],
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
