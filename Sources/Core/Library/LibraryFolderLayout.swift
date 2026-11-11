import Foundation
import Metadata

/// Where a file copied into the library folder goes, relative to it (ADR 0124):
/// `<album artist, else artist>/<album>/<disc-track title>.<extension>`, as Swinsian lays out
/// its library folder. The track number has two digits, after the disc number and a hyphen when
/// the album has more than one disc. A file with no track number is named by its title alone,
/// one with no title by its own file name, and a missing artist or album is "Unknown Artist" or
/// "Unknown Album". Every part, the extension too, goes through `safeName`, so tags and a
/// staged file's name give three components inside the library folder, none `.` or `..`.
func libraryFolderPath(for tags: TrackTags, of source: String) -> String {
    let artist = folderName(tags.albumArtist ?? tags.artist, else: "Unknown Artist")
    let album = folderName(tags.album, else: "Unknown Album")
    let title = tags.title.flatMap(nonEmpty) ?? displayName(source)
    let number = tags.trackNumber.map { track in
        let digits = String(format: "%02d", track)
        let multiDisc = (tags.discTotal ?? 0) > 1 || (tags.discNumber ?? 1) > 1
        return multiDisc ? "\(tags.discNumber ?? 1)-\(digits) " : "\(digits) "
    }
    let ext = safeName((source as NSString).pathExtension, maxBytes: maxExtensionBytes)
    return artist + "/" + album + "/" + fileName(stem: (number ?? "") + title, extension: ext)
}

/// Why a file has no place in the library folder.
enum LayoutProblem: Error {
    /// Its tags don't read.
    case unreadable(String)
    /// A folder on the way to its place can't be listed.
    case unlisted(String)
}

/// Where the file at `source` goes in the library folder of `listings` by its tags:
/// `libraryFolderPath`, with each part already there named as its folder lists it
/// (`listedPath`). Reads the file and lists folders, so call it off the main thread.
func layoutDestination(of source: String, in listings: LibraryFolderListings)
    throws(LayoutProblem) -> String
{
    let tags: TrackTags
    do {
        tags = try readMetadata(at: URL(fileURLWithPath: source, isDirectory: false)).metadata.tags
    } catch {
        throw .unreadable("\(error)")
    }
    do {
        return try listedPath(libraryFolderPath(for: tags, of: source), in: listings)
    } catch {
        throw .unlisted("\(error)")
    }
}

/// The most bytes a name may have: APFS and HFS+ take 255 in UTF-8.
private let maxNameBytes = 255
/// The most bytes an extension keeps, so a name its source gave a long one still has room for
/// its stem. Audio files' extensions have four or five.
private let maxExtensionBytes = 16

private func nonEmpty(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func folderName(_ tag: String?, else fallback: String) -> String {
    let name = safeName(tag ?? "", maxBytes: maxNameBytes)
    return name.isEmpty ? fallback : name
}

/// `stem.extension`, the stem cut short so the whole name fits; `stem` alone when the extension
/// is empty.
private func fileName(stem: String, extension ext: String) -> String {
    let suffix = ext.isEmpty ? "" : "." + ext
    let name = safeName(stem, maxBytes: maxNameBytes - suffix.utf8.count)
    return (name.isEmpty ? "Untitled" : name) + suffix
}

/// `text` as one path component a Mac volume or an SMB share takes: a colon before a space
/// becomes ` - ` and any other colon `-`, so a subtitle still reads as one; `/` and the other
/// characters Windows and SMB servers refuse (`\ * ? " < > |`) become `_`; control characters
/// go, and leading dots and spaces go, since a name starting with a dot is hidden and the
/// scanner skips it. Trailing dots and spaces go too, which SMB servers drop or refuse. The
/// result is cut, at a whole character, to `maxBytes` of UTF-8, and may be empty.
func safeName(_ text: String, maxBytes: Int) -> String {
    let unsafe = Set("/\\*?\"<>|")
    let colons = text.precomposedStringWithCanonicalMapping
        .replacingOccurrences(of: #"\s*:\s+"#, with: " - ", options: .regularExpression)
        .replacingOccurrences(of: ":", with: "-")
    var name = String(
        colons.compactMap { character -> Character? in
            if unsafe.contains(character) { return "_" }
            if character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) {
                return nil
            }
            return character
        })
    let edges = CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines)
    name = name.trimmingCharacters(in: edges)
    while name.utf8.count > maxBytes { name.removeLast() }
    // Cutting can leave a space or a dot at the end.
    return name.trimmingCharacters(in: edges)
}
