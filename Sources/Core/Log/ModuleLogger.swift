import os

/// The app's bundle identifier, and the subsystem every log line goes under. `scripts/bundle`
/// reads this line to write `CFBundleIdentifier` into the `.app`, so keep it a plain literal.
public let bundleIdentifier = "com.dylanfisher.MusicPlayer"

/// The app's name as people see it: the menu bar, the window title, the Dock and the app
/// switcher. `scripts/bundle` reads this line to name the `.app` and write `CFBundleName` and
/// `CFBundleDisplayName`, so keep it a plain literal.
public let appDisplayName = "Music Player"

/// The app's folder name under Application Support and Caches.
public let appDirectoryName = "MusicPlayer"

/// A logger for the calling module, with the module's name as its category:
/// `private let logger = moduleLogger()` at the top of a file. Never call it from the real-time
/// path.
public func moduleLogger(fileID: String = #fileID) -> Logger {
    Logger(subsystem: bundleIdentifier, category: category(fileID: fileID))
}

/// `error`'s description with `path` replaced by "the track's file", for the public part of a
/// log line that logs `path` itself hashed: `MetadataError`, which the decoders throw, starts
/// with the file's path, and the log keeps paths private (ADR 0118).
public func logText(_ error: any Error, without path: String) -> String {
    "\(error)".replacingOccurrences(of: path, with: "the track's file")
}

/// `#fileID` is `Module/File.swift`.
func category(fileID: String) -> String {
    guard let slash = fileID.firstIndex(of: "/") else {
        preconditionFailure("#fileID \"\(fileID)\" has no module prefix")
    }
    return String(fileID[..<slash])
}
