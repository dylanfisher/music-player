/// Something wrong with one line of a playlist file. The line is skipped and the rest is read.
public struct PlaylistFileProblem: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: Equatable, Sendable {
        /// Over `PlaylistFile.maximumLineBytes`.
        case lineTooLong
        /// Not UTF-8 in an M3U8 file, or holding a NUL.
        case invalidText
        /// A URL whose scheme isn't `file`, such as `http`. Only files on this Mac are read.
        case scheme(String)
        /// A `file:` URL naming another host, or with a broken `%` escape.
        case badFileURL
        /// A Windows path such as `C:\Music\a.mp3`, which no file on this Mac has.
        case windowsPath
        /// A PLS line that isn't `[playlist]`, a comment or a key it knows.
        case unknownLine
        /// Past `PlaylistFile.maximumEntries`; this line and the rest weren't read.
        case tooManyEntries
    }

    /// From 1.
    public var line: Int
    public var kind: Kind

    init(line: Int, _ kind: Kind) {
        self.line = line
        self.kind = kind
    }

    public var description: String {
        let what =
            switch kind {
            case .lineTooLong: "longer than \(PlaylistFile.maximumLineBytes) bytes"
            case .invalidText: "not UTF-8 text, or holds a NUL"
            case .scheme(let scheme): "a \(scheme): address; only files on this Mac are read"
            case .badFileURL: "a file: address for another host, or with a broken % escape"
            case .windowsPath: "a Windows path"
            case .unknownLine: "not a PLS line this app reads"
            case .tooManyEntries:
                "past \(PlaylistFile.maximumEntries) entries; the rest weren't read"
            }
        return "line \(line): \(what)"
    }
}
