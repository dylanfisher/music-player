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
            name: "HALOutput",
            path: "Sources/Core/HALOutput",
            swiftSettings: strictSwift
        ),
        .executableTarget(
            name: "MusicPlayer",
            dependencies: ["HALOutput"],
            path: "Sources/App/MusicPlayer",
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "HALOutputTests",
            dependencies: ["HALOutput"],
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
