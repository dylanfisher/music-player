import CoreFoundation
import Foundation
import Metadata
import Settings

/// Reads the `Library.xml` iTunes and Music export (ADR 0033). Only the keys below are read;
/// the dozens of others a track has are ignored, since each Music release adds some.
extension PlayerLibrary {
    /// Read whole and parsed in memory, which takes several times this; the owner's 43k tracks
    /// export to about 60 MB.
    static let maximumXMLBytes = 256 << 20

    /// Reads the file at `url` without following a link, and only if it's a regular file under
    /// `maximumXMLBytes`.
    init(iTunesXMLAt url: URL, now: Double = Date().timeIntervalSince1970) throws {
        let source: FileSource
        do throws(ParseFailure) {
            source = try FileSource(path: url.path, hints: .none)
        } catch {
            throw PlayerImportError.unreadable(error.detail)
        }
        guard source.size <= Self.maximumXMLBytes else {
            throw PlayerImportError.tooLarge(source.size, maximum: Self.maximumXMLBytes)
        }
        let data: Data
        do throws(ParseFailure) {
            data = try source.readData(0..<source.size)
        } catch {
            throw PlayerImportError.unreadable(error.detail)
        }
        try self.init(iTunesXML: data, source: url.path, now: now)
    }

    init(iTunesXML data: Data, source: String, now: Double) throws {
        self.init(player: .iTunes, source: source)
        guard data.count <= Self.maximumXMLBytes else {
            throw PlayerImportError.tooLarge(data.count, maximum: Self.maximumXMLBytes)
        }
        let root: Any
        do {
            root = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw PlayerImportError.notALibrary(
                "not a property list: \(error.localizedDescription)")
        }
        guard let root = root as? [String: Any] else {
            throw PlayerImportError.notALibrary("its top level isn't a dictionary")
        }
        guard let tracks = root[ITunesKey.tracks] as? [String: Any] else {
            throw PlayerImportError.notALibrary("it has no \(ITunesKey.tracks) dictionary")
        }
        let paths = readTracks(tracks, now: now)
        guard let playlists = (root[ITunesKey.playlists] ?? [Any]()) as? [Any] else {
            throw PlayerImportError.notALibrary("its \(ITunesKey.playlists) aren't a list")
        }
        readPlaylists(playlists, tracks: paths)
    }

    /// Reads each track, in Track ID order, and returns each one's path by ID, or nil for a
    /// track with no file.
    private mutating func readTracks(_ tracks: [String: Any], now: Double) -> [Int64: String?] {
        var paths: [Int64: String?] = [:]
        var entries: [(Int64, [String: Any])] = []
        for (key, value) in tracks {
            guard let track = value as? [String: Any] else {
                note(
                    PlayerLibraryProblem(
                        PlayerLibraryProblem.track(key),
                        .wrongType("its entry", expected: "a dictionary")))
                continue
            }
            guard let id = integer(track[ITunesKey.trackID]) else {
                note(
                    PlayerLibraryProblem(
                        PlayerLibraryProblem.track(key),
                        .wrongType(ITunesKey.trackID, expected: Int.typeName)))
                continue
            }
            entries.append((id, track))
        }
        entries.sort { $0.0 < $1.0 }
        if entries.count > Self.maximumTracks {
            note(PlayerLibraryProblem(ITunesKey.tracks, .tooMany(.tracks)))
            entries.removeLast(entries.count - Self.maximumTracks)
        }
        for (id, entry) in entries {
            let item = PlayerLibraryProblem.track(id)
            guard let location = entry[ITunesKey.location] else {
                tracksWithoutFiles += 1
                paths[id] = .some(nil)
                continue
            }
            guard let location = location as? String,
                let text = checkedText(location, item, maximumBytes: Self.maximumPathBytes)
            else {
                if !(location is String) {
                    note(
                        PlayerLibraryProblem(
                            item, .wrongType(ITunesKey.location, expected: String.typeName))
                    )
                }
                continue
            }
            guard text.lowercased().hasPrefix("file:"),
                case .absolute(let written) = PlaylistEntry(Substring(text))
            else {
                note(PlayerLibraryProblem(item, .badFileURL))
                continue
            }
            var track = PlayerTrack(path: folded(written))
            track.plays = count(entry[ITunesKey.playCount], item, ITunesKey.playCount)
            track.skips = count(entry[ITunesKey.skipCount], item, ITunesKey.skipCount)
            track.lastPlayedSeconds = date(
                entry[ITunesKey.playDate], item, ITunesKey.playDate, now: now)
            track.addedSeconds = date(
                entry[ITunesKey.dateAdded], item, ITunesKey.dateAdded, now: now)
            if !flag(entry[ITunesKey.ratingComputed], item, ITunesKey.ratingComputed) {
                track.rating = stars(entry[ITunesKey.rating], item)
            }
            track.loved =
                flag(entry[ITunesKey.loved], item, ITunesKey.loved)
                || flag(entry[ITunesKey.favorited], item, ITunesKey.favorited)
            paths[id] = add(track)
        }
        return paths
    }

    private mutating func readPlaylists(_ playlists: [Any], tracks: [Int64: String?]) {
        var entryCount = 0
        for (offset, value) in playlists.enumerated() {
            guard self.playlists.count < Self.maximumPlaylists else {
                note(
                    PlayerLibraryProblem(ITunesKey.playlists, .tooMany(.playlists)))
                return
            }
            let item = PlayerLibraryProblem.playlist(Int64(offset + 1))
            guard let playlist = value as? [String: Any] else {
                note(PlayerLibraryProblem(item, .wrongType("its entry", expected: "a dictionary")))
                continue
            }
            if flag(playlist[ITunesKey.master], item, ITunesKey.master)
                || playlist[ITunesKey.distinguishedKind] != nil
                || flag(playlist[ITunesKey.folder], item, ITunesKey.folder)
            {
                builtInPlaylists += 1
                continue
            }
            guard let written = playlist[ITunesKey.name] as? String else {
                note(
                    PlayerLibraryProblem(
                        item, .wrongType(ITunesKey.name, expected: String.typeName)))
                continue
            }
            guard let name = checkedText(written, item, maximumBytes: Self.maximumNameBytes)
            else { continue }
            let named = PlayerLibraryProblem.playlist(named: name)
            var imported = PlayerPlaylist(
                name: name, kind: playlist[ITunesKey.smartInfo] == nil ? .manual : .smartAsManual)
            guard let items = (playlist[ITunesKey.items] ?? [Any]()) as? [Any] else {
                note(PlayerLibraryProblem(named, .wrongType(ITunesKey.items, expected: "a list")))
                continue
            }
            for entry in items {
                guard entryCount < Self.maximumEntries else {
                    note(PlayerLibraryProblem(named, .tooMany(.entries)))
                    break
                }
                entryCount += 1
                guard let id = integer((entry as? [String: Any])?[ITunesKey.trackID]) else {
                    note(
                        PlayerLibraryProblem(
                            named, .wrongType(ITunesKey.trackID, expected: Int.typeName)))
                    continue
                }
                switch tracks[id] {
                case .some(.some(let path)): imported.paths.append(path)
                case .some(.none): imported.entriesWithoutFiles += 1
                case .none: note(PlayerLibraryProblem(named, .unknownTrack(id)))
                }
            }
            self.playlists.append(imported)
        }
    }

    private mutating func count(_ value: Any?, _ item: String, _ key: String) -> Int {
        guard let value else { return 0 }
        guard let number = integer(value) else {
            note(PlayerLibraryProblem(item, .wrongType(key, expected: Int.typeName)))
            return 0
        }
        guard number >= 0, number <= Int32.max else {
            note(PlayerLibraryProblem(item, .outOfRange(key, "\(number)")))
            return 0
        }
        return Int(number)
    }

    private mutating func date(_ value: Any?, _ item: String, _ key: String, now: Double)
        -> Double?
    {
        guard let value else { return nil }
        guard let date = value as? Date else {
            note(PlayerLibraryProblem(item, .wrongType(key, expected: "a date")))
            return nil
        }
        return checkedDate(date.timeIntervalSince1970, item, key, now: now)
    }

    /// Stars from Music's 0 to 100, a star each 20.
    private mutating func stars(_ value: Any?, _ item: String) -> Int? {
        guard let value else { return nil }
        guard let rating = integer(value), (0...100).contains(rating) else {
            note(PlayerLibraryProblem(item, .outOfRange(ITunesKey.rating, "\(value)")))
            return nil
        }
        let stars = Int(rating + 10) / 20
        return stars == 0 ? nil : stars
    }

    private mutating func flag(_ value: Any?, _ item: String, _ key: String) -> Bool {
        guard let value else { return false }
        guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let flag = value as? Bool
        else {
            note(PlayerLibraryProblem(item, .wrongType(key, expected: Bool.typeName)))
            return false
        }
        return flag
    }
}

/// A property list integer, which isn't a boolean or a real.
private func integer(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(),
        !CFNumberIsFloatType(number)
    else { return nil }
    return number.int64Value
}

/// The keys of `Library.xml` the reader uses.
private enum ITunesKey {
    static let tracks = "Tracks"
    static let playlists = "Playlists"
    static let trackID = "Track ID"
    static let location = "Location"
    static let playCount = "Play Count"
    static let skipCount = "Skip Count"
    static let playDate = "Play Date UTC"
    static let dateAdded = "Date Added"
    static let rating = "Rating"
    static let ratingComputed = "Rating Computed"
    static let loved = "Loved"
    static let favorited = "Favorited"
    static let name = "Name"
    static let master = "Master"
    static let distinguishedKind = "Distinguished Kind"
    static let folder = "Folder"
    static let smartInfo = "Smart Info"
    static let items = "Playlist Items"
}
