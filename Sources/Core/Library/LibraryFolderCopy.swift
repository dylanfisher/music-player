import Darwin
import Foundation
import Metadata

/// Copies the audio file at `source` into `libraryFolder`, at the path its tags give it
/// (ADR 0124), and returns the copy's path. The source is only read. A file already at that
/// path is never replaced: the copy is refused instead. A copy that fails partway is removed,
/// so no torn file is left for a scan to read. Reads and writes the volumes, so call it off the
/// main thread.
public func copyIntoLibraryFolder(_ source: String, libraryFolder: String)
    throws(CopyError) -> String
{
    let tags: TrackTags
    do {
        tags = try readMetadata(at: URL(fileURLWithPath: source, isDirectory: false)).metadata.tags
    } catch {
        throw .unreadable(source, "\(error)")
    }
    let destination = libraryFolder + "/" + libraryFolderPath(for: tags, of: source)
    do {
        try FileManager.default.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
    } catch {
        throw .failed(source, destination, error.localizedDescription)
    }
    let input = open(source, O_RDONLY)
    guard input >= 0 else { throw .failed(source, destination, errorText(errno)) }
    defer { close(input) }
    // O_EXCL makes a file there, or one another copy put there a moment ago, fail the open
    // rather than be overwritten.
    let output = open(destination, O_WRONLY | O_CREAT | O_EXCL, 0o644)
    guard output >= 0 else {
        let code = errno
        if code == EEXIST { throw .alreadyThere(source, destination) }
        throw .failed(source, destination, errorText(code))
    }
    // An SMB write can fail as late as the close.
    var failure = fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 ? nil : errno
    if close(output) != 0, failure == nil { failure = errno }
    if let failure {
        // This call made the file, so removing it touches nothing else.
        guard unlink(destination) == 0 else {
            throw .failed(
                source, destination,
                "\(errorText(failure)), and the partial copy couldn't be removed:"
                    + " \(errorText(errno))")
        }
        throw .failed(source, destination, errorText(failure))
    }
    return destination
}

/// Why a dropped file wasn't copied into the library folder.
public enum CopyError: Error, Equatable, CustomStringConvertible {
    /// Its tags didn't read, so it has no place in the folder.
    case unreadable(String, String)
    /// A file is already at the path its tags give it.
    case alreadyThere(String, String)
    case failed(String, String, String)

    public var description: String {
        switch self {
        case .unreadable(let source, let detail):
            "\(source): not copied, its tags don't read: \(detail)"
        case .alreadyThere(let source, let destination):
            "\(source): not copied, \(destination) is already there"
        case .failed(let source, let destination, let detail):
            "\(source): couldn't copy to \(destination): \(detail)"
        }
    }
}
