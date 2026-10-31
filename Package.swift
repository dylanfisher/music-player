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
            name: "RingBufferTests",
            dependencies: ["RingBuffer"],
            swiftSettings: strictSwift
        ),
    ],
    swiftLanguageModes: [.v6]
)
