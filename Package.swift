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
            name: "FuzzyMatch",
            path: "Sources/Primitives/FuzzyMatch",
            swiftSettings: strictSwift
        ),
        .target(
            name: "KeyChord",
            path: "Sources/Primitives/KeyChord",
            swiftSettings: strictSwift
        ),
        .target(
            name: "LocalSocket",
            path: "Sources/Primitives/LocalSocket",
            swiftSettings: strictSwift
        ),
        .target(
            name: "LocalNetwork",
            path: "Sources/Primitives/LocalNetwork",
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
            dependencies: [
                "DisplayText", "HALRender", "Log", "Metadata", "Playback", "RingBuffer",
            ],
            path: "Sources/Core/HALOutput",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Playback",
            dependencies: ["DisplayText", "Log", "Metadata"],
            path: "Sources/Core/Playback",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Metadata",
            dependencies: ["DisplayText"],
            path: "Sources/Core/Metadata",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Library",
            dependencies: [
                "DisplayText", "Log", "Metadata", "Recommender", "Settings", "SQLite",
            ],
            path: "Sources/Core/Library",
            swiftSettings: strictSwift
        ),
        .target(
            name: "TagWriter",
            dependencies: ["Log", "Metadata"],
            path: "Sources/Core/TagWriter",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Artwork",
            dependencies: ["Log", "Metadata"],
            path: "Sources/Core/Artwork",
            swiftSettings: strictSwift
        ),
        .target(
            name: "UPnP",
            dependencies: ["DisplayText", "LocalNetwork"],
            path: "Sources/Core/UPnP",
            swiftSettings: strictSwift
        ),
        .target(
            name: "UPnPOutput",
            dependencies: ["LocalNetwork", "Log", "Metadata", "Playback", "UPnP"],
            path: "Sources/Core/UPnPOutput",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Receiver",
            dependencies: ["LocalNetwork", "Log", "UPnP"],
            path: "Sources/Core/Receiver",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Recommender",
            dependencies: ["DisplayText", "LocalNetwork", "Settings"],
            path: "Sources/Core/Recommender",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Settings",
            dependencies: ["KeyChord", "LocalNetwork", "Log", "Metadata", "Playback", "TagWriter"],
            path: "Sources/Core/Settings",
            swiftSettings: strictSwift
        ),
        .target(
            name: "BarView",
            dependencies: ["Settings"],
            path: "Sources/Core/BarView",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Analysis",
            dependencies: [
                "DisplayText", "HALOutput", "Library", "Log", "Metadata", "Playback", "Settings",
            ],
            path: "Sources/Core/Analysis",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Discogs",
            dependencies: [
                "DisplayText", "Library", "Log", "Metadata", "Recommender", "SQLite", "Settings",
                "TagWriter",
            ],
            path: "Sources/Core/Discogs",
            swiftSettings: strictSwift,
            // The system library, which the SDK's zlib module declares.
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "Commands",
            dependencies: ["DisplayText", "KeyChord", "Log", "Receiver", "Settings"],
            path: "Sources/Core/Commands",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Scripting",
            dependencies: ["Commands", "DisplayText", "LocalSocket", "Playback", "Settings"],
            path: "Sources/Core/Scripting",
            swiftSettings: strictSwift
        ),
        .target(
            name: "LibraryBrowser",
            dependencies: [
                "Analysis", "Artwork", "BarView", "Commands", "DisplayText", "KeyChord", "Library",
                "Log", "Metadata", "Playback", "Settings",
            ],
            path: "Sources/Features/LibraryBrowser",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Palette",
            dependencies: ["DisplayText", "FuzzyMatch", "KeyChord", "Log", "Settings"],
            path: "Sources/Features/Palette",
            swiftSettings: strictSwift
        ),
        .target(
            name: "PlaylistEditor",
            dependencies: ["DisplayText", "Library"],
            path: "Sources/Features/PlaylistEditor",
            swiftSettings: strictSwift
        ),
        .target(
            name: "TagEditor",
            dependencies: [
                "Artwork", "Commands", "DisplayText", "Library", "Log", "Metadata", "Settings",
                "TagWriter",
            ],
            path: "Sources/Features/TagEditor",
            swiftSettings: strictSwift
        ),
        .target(
            name: "DiscogsTagger",
            dependencies: [
                "Discogs", "DisplayText", "Library", "Log", "Metadata", "Settings", "TagWriter",
            ],
            path: "Sources/Features/DiscogsTagger",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Downloads",
            dependencies: [
                "Discogs", "DisplayText", "Library", "Log", "Recommender", "Settings", "TagWriter",
            ],
            path: "Sources/Features/Downloads",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Spectrum",
            dependencies: ["Analysis", "DisplayText", "Library"],
            path: "Sources/Features/Spectrum",
            swiftSettings: strictSwift
        ),
        .target(
            name: "SettingsWindow",
            dependencies: ["Commands", "DisplayText", "KeyChord", "Log", "Settings"],
            path: "Sources/Features/SettingsWindow",
            swiftSettings: strictSwift
        ),
        .target(
            name: "NowPlaying",
            dependencies: [
                "Artwork", "BarView", "Commands", "DisplayText", "Library", "Log", "Metadata",
                "Playback", "Settings",
            ],
            path: "Sources/Features/NowPlaying",
            swiftSettings: strictSwift
        ),
        .target(
            name: "QueueView",
            dependencies: ["Commands", "DisplayText", "KeyChord", "Library", "Log", "Playback"],
            path: "Sources/Features/QueueView",
            swiftSettings: strictSwift
        ),
        .executableTarget(
            name: "MusicPlayer",
            dependencies: [
                "Analysis", "Artwork", "Commands", "Discogs", "DiscogsTagger", "DisplayText",
                "HALOutput", "KeyChord", "Library",
                "LibraryBrowser", "LocalNetwork", "LocalSocket", "Log", "Metadata", "NowPlaying",
                "Playback", "PlaylistEditor", "QueueView", "Palette", "Receiver", "Scripting",
                "SQLite", "Settings", "SettingsWindow", "Spectrum", "TagEditor", "TagWriter",
                "UPnP", "UPnPOutput",
            ],
            path: "Sources/App/MusicPlayer",
            swiftSettings: strictSwift
        ),
        // The `music-player` command line, which scripts/bundle puts beside the app.
        .executableTarget(
            name: "ScriptTool",
            dependencies: ["Commands", "DisplayText", "LocalSocket", "Scripting", "Settings"],
            path: "Sources/App/ScriptTool",
            swiftSettings: strictSwift
        ),
        .target(
            name: "Fixtures",
            dependencies: ["HALOutput", "HALRender", "Library", "LocalNetwork", "Log", "Metadata"],
            path: "Sources/Tools/Fixtures",
            swiftSettings: strictSwift,
            // Gzip for the Discogs dump fixtures.
            linkerSettings: [.linkedLibrary("z")]
        ),
        .executableTarget(
            name: "GenerateFixtures",
            dependencies: ["Fixtures"],
            path: "Sources/Tools/GenerateFixtures",
            swiftSettings: strictSwift
        ),
        .executableTarget(
            name: "TagCorpus",
            dependencies: ["Discogs", "Fixtures", "Library", "Metadata", "Settings", "TagWriter"],
            path: "Sources/Tools/TagCorpus",
            swiftSettings: strictSwift
        ),
        .executableTarget(
            name: "DiscogsImport",
            dependencies: ["Discogs", "Library", "Settings"],
            path: "Sources/Tools/DiscogsImport",
            swiftSettings: strictSwift
        ),
        .executableTarget(
            name: "FailureDrill",
            dependencies: ["Fixtures", "Library", "Log", "SQLite", "Settings", "TagWriter"],
            path: "Sources/Tools/FailureDrill",
            swiftSettings: strictSwift
        ),
        .target(
            name: "FuzzCoverage",
            path: "Sources/Tools/FuzzCoverage",
            cSettings: strictC
        ),
        .executableTarget(
            name: "Fuzz",
            dependencies: [
                "Discogs", "Fixtures", "FuzzCoverage", "HALOutput", "Library", "LocalNetwork",
                "Log", "Metadata", "Receiver", "Recommender", "SQLite", "Settings", "TagWriter",
                "UPnP",
            ],
            path: "Sources/Tools/Fuzz",
            swiftSettings: strictSwift
        ),
        .executableTarget(
            name: "Bench",
            dependencies: [
                "Analysis", "Artwork", "Commands", "Discogs", "DiscogsTagger", "DisplayText",
                "Fixtures", "HALOutput",
                "Library",
                "LibraryBrowser",
                "Metadata", "Palette", "Playback", "QueueView", "SQLite", "Settings", "TagEditor",
                "TagWriter",
            ],
            path: "Sources/Tools/Bench",
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "AnalysisTests",
            dependencies: ["Analysis", "Fixtures", "Library", "Metadata", "Playback", "Settings"],
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
            name: "CommandsTests",
            dependencies: ["Commands", "KeyChord", "Receiver", "Settings"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "DiscogsTests",
            dependencies: [
                // DiscogsImport, built for the tests that kill it partway through an import.
                "Discogs", "DiscogsImport", "Fixtures", "Library", "Metadata", "Recommender",
                "SQLite", "Settings", "TagWriter",
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "DiscogsTaggerTests",
            dependencies: [
                "Discogs", "DiscogsTagger", "Fixtures", "Library", "Metadata", "Recommender",
                "Settings", "TagWriter",
            ],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "DownloadsTests",
            dependencies: ["Discogs", "Downloads", "Library", "LocalNetwork", "Recommender"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "DisplayTextTests",
            dependencies: ["DisplayText"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "FailureDrillTests",
            dependencies: ["FailureDrill"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "FixturesTests",
            dependencies: ["Fixtures"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "FuzzTests",
            dependencies: ["Fixtures", "Fuzz", "FuzzCoverage"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "HALOutputTests",
            dependencies: ["Fixtures", "HALOutput", "HALRender", "Log", "Playback"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "HALRenderTests",
            dependencies: ["HALRender", "RingBuffer"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "FuzzyMatchTests",
            dependencies: ["FuzzyMatch"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "KeyChordTests",
            dependencies: ["KeyChord"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "LibraryTests",
            dependencies: [
                "Fixtures", "Library", "Metadata", "Recommender", "Settings", "SQLite", "TagWriter",
            ],
            exclude: ["Crashes"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "LibraryBrowserTests",
            dependencies: [
                "Analysis", "Artwork", "Commands", "DisplayText", "Fixtures", "KeyChord", "Library",
                "LibraryBrowser",
                "Metadata", "Playback", "SQLite", "Settings",
            ],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "LocalSocketTests",
            dependencies: ["LocalSocket"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "LocalNetworkTests",
            dependencies: ["Fixtures", "LocalNetwork"],
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
            dependencies: [
                "Artwork", "Commands", "Fixtures", "Library", "LibraryBrowser", "Metadata",
                "MusicPlayer", "NowPlaying", "Playback", "QueueView", "Settings", "SettingsWindow",
            ],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "NowPlayingTests",
            dependencies: [
                "Artwork", "Commands", "Fixtures", "HALOutput", "Library", "Metadata", "NowPlaying",
                "Playback", "Settings",
            ],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "PaletteTests",
            dependencies: ["FuzzyMatch", "KeyChord", "Palette", "Settings"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "PlaylistEditorTests",
            dependencies: ["Library", "PlaylistEditor", "Settings"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "PlaybackTests",
            dependencies: ["Fixtures", "Playback"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "QueueViewTests",
            dependencies: ["Commands", "DisplayText", "Library", "Playback", "QueueView"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "ScriptingTests",
            dependencies: ["Commands", "LocalSocket", "Playback", "Scripting", "Settings"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "SpectrumTests",
            dependencies: ["Analysis", "Library", "Spectrum"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "UPnPTests",
            dependencies: ["Fixtures", "LocalNetwork", "UPnP"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "UPnPOutputTests",
            dependencies: ["Fixtures", "LocalNetwork", "Playback", "UPnP", "UPnPOutput"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "SettingsTests",
            dependencies: ["Metadata", "Settings", "TagWriter"],
            exclude: ["Crashes"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "SettingsWindowTests",
            dependencies: ["Commands", "Fixtures", "KeyChord", "Settings", "SettingsWindow"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "TagCorpusTests",
            dependencies: ["TagCorpus"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "TagEditorTests",
            dependencies: ["Commands", "Fixtures", "Metadata", "TagEditor", "TagWriter"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "TagWriterTests",
            dependencies: ["Fixtures", "Metadata", "TagWriter"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "SQLiteTests",
            dependencies: ["SQLite"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "ReceiverTests",
            dependencies: ["Fixtures", "LocalNetwork", "Receiver", "UPnP"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "RecommenderTests",
            dependencies: ["Fixtures", "LocalNetwork", "Recommender", "Settings"],
            resources: [.copy("Fixtures")],
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
