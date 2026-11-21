import Foundation

/// How the argument commands read their arguments: Seek To and Set Volume a plain decimal
/// number, the web remote's track and queue commands IDs and positions, nothing else, so a
/// remote's or a script's mistake is refused rather than read as something near it.
public enum CommandArgument {
    /// The most Seek To takes, a day: no track is longer.
    static let maximumSeconds = 86_400.0

    /// Seek To's: seconds from 0 to a day.
    public static func seconds(_ text: String) -> Double? {
        number(text).flatMap { (0...maximumSeconds).contains($0) ? $0 : nil }
    }

    /// Set Volume's: decibels within `range`.
    public static func decibels(_ text: String, in range: ClosedRange<Double>) -> Double? {
        number(text).flatMap { range.contains($0) ? $0 : nil }
    }

    /// What Play Tracks and Queue Tracks act on.
    public enum Tracks: Equatable, Sendable {
        /// Tracks by ID, played or queued in this order.
        case tracks([Int64])
        /// An album's tracks in disc and track order, played from `start` when given.
        case album(Int64, start: Int64?)
    }

    /// The most track IDs Play Tracks and Queue Tracks take, which fit a command's argument.
    static let maximumTracks = 100

    /// Play Tracks' and Queue Tracks': `tracks:` and up to `maximumTracks` IDs between commas,
    /// or `album:` and an ID, then for Play Tracks `:` and the ID of the track to start from.
    public static func tracks(_ text: String, startAllowed: Bool) -> Tracks? {
        if text.hasPrefix(tracksPrefix) {
            let ids = text.dropFirst(tracksPrefix.count).split(
                separator: ",", omittingEmptySubsequences: false
            ).map(id)
            guard (1...maximumTracks).contains(ids.count), !ids.contains(nil) else { return nil }
            return .tracks(ids.compactMap { $0 })
        }
        guard text.hasPrefix(albumPrefix) else { return nil }
        let parts = text.dropFirst(albumPrefix.count).split(
            separator: ":", omittingEmptySubsequences: false)
        guard (1...(startAllowed ? 2 : 1)).contains(parts.count), let album = id(parts[0])
        else { return nil }
        guard parts.count == 2 else { return .album(album, start: nil) }
        return id(parts[1]).map { .album(album, start: $0) }
    }

    static let tracksPrefix = "tracks:"
    static let albumPrefix = "album:"
    /// Play Tracks' argument, as `tracks` reads it.
    public static let playTracksHelp =
        "tracks: and up to \(maximumTracks) track IDs between commas, or album:, an album ID,"
        + " and : and a track ID to start from"
    /// Queue Tracks' argument.
    public static let queueTracksHelp =
        "tracks: and up to \(maximumTracks) track IDs between commas, or album: and an album ID"

    /// Move in Queue's `<stamp>:<from>:<to>` (`count` 2) and Remove from Queue at's
    /// `<stamp>:<position>` (`count` 1): the queue's change stamp as the remote's state gave it,
    /// so an edit to a queue that changed since is refused, and positions from 0 in play order.
    public static func queuePlaces(_ text: String, count: Int) -> (stamp: Int, places: [Int])? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(natural)
        guard parts.count == count + 1, let stamp = parts[0], !parts.contains(nil) else {
            return nil
        }
        return (stamp, parts.dropFirst().compactMap { $0 })
    }

    /// An ID: 1 to 18 digits, not 0.
    private static func id(_ text: Substring) -> Int64? {
        natural(text).flatMap { $0 > 0 ? Int64($0) : nil }
    }

    /// 1 to 18 ASCII digits.
    private static func natural(_ text: Substring) -> Int? {
        guard (1...18).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return Int(text)
    }

    /// Digits with an optional sign and fraction, at most 16 characters.
    private static func number(_ text: String) -> Double? {
        let digits = text.drop { $0 == "-" || $0 == "+" }
        guard text.count <= 16, text.count - digits.count <= 1, !digits.isEmpty,
            digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
            digits.filter({ $0 == "." }).count <= 1, digits.first != ".", digits.last != "."
        else { return nil }
        return Double(text)
    }
}
