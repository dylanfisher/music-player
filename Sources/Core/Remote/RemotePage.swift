import CacheFolder
import Foundation
import LocalNetwork
import Metadata

/// The web remote's static files (ADR 0215): a fixed list, read once at start into replies
/// keyed by exact path, so nothing from a request's path reaches the file system.
public struct RemotePage: Sendable {
    /// Each file the page is made of, by the path it's served at, its name in the bundle's
    /// `Remote` folder and its type. `icon.png` is made by `scripts/bundle`.
    static let files: [(path: String, name: String, type: String)] = [
        ("/", "index.html", "text/html; charset=utf-8"),
        ("/style.css", "style.css", "text/css; charset=utf-8"),
        ("/app.js", "app.js", "text/javascript; charset=utf-8"),
        ("/logic.js", "logic.js", "text/javascript; charset=utf-8"),
        ("/icons.js", "icons.js", "text/javascript; charset=utf-8"),
        ("/icon.png", "icon.png", pngMIMEType),
    ]

    /// The page's own scripts and styles only, so a name from the library that reached the
    /// page as markup would run nothing; reads and art go to any Mac's address.
    static let contentPolicy =
        "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob:;"
        + " connect-src 'self' http:; manifest-src 'self'; base-uri 'none'; form-action 'none';"
        + " frame-ancestors 'none'"

    private let replies: [String: RemoteReply]

    /// Reads every file in `files` from `folder`, throwing for the first that can't be read.
    public init(folder: URL) throws {
        var contents: [String: [UInt8]] = [:]
        for file in Self.files {
            let url = folder.appendingPathComponent(file.name, isDirectory: false)
            do {
                contents[file.name] = Array(try Data(contentsOf: url))
            } catch {
                throw PageMissing(name: file.name, reason: "\(error)")
            }
        }
        self.init(contents: contents)
    }

    /// The page from each file's bytes by name; a name without bytes isn't served.
    init(contents: [String: [UInt8]]) {
        var replies: [String: RemoteReply] = [:]
        for file in Self.files {
            guard let body = contents[file.name] else { continue }
            var fields = [
                (HTTPWord.cacheControl, HTTPWord.noCache), (HTTPWord.etag, Self.tag(body)),
                ("X-Content-Type-Options", "nosniff"),
            ]
            if file.path == "/" {
                // No referrer, so a link out of the page doesn't say which Mac it came from.
                fields += [
                    ("Content-Security-Policy", Self.contentPolicy),
                    ("Referrer-Policy", "no-referrer"),
                ]
            }
            replies[file.path] = RemoteReply(
                .ok, contentType: file.type, body: body, fields: fields)
        }
        self.replies = replies
    }

    /// The reply for `path`, a 304 when `ifNoneMatch` is its tag, or nil for no file there.
    func reply(_ path: String, ifNoneMatch: String?) -> RemoteReply? {
        guard let reply = replies[path == "/index.html" ? "/" : path] else { return nil }
        guard let tag = reply.fields.first(where: { $0.0 == HTTPWord.etag })?.1, ifNoneMatch == tag
        else { return reply }
        return RemoteReply(.notModified, fields: reply.fields)
    }

    private static func tag(_ body: [UInt8]) -> String {
        "\"" + CacheFolder.name([Data(body).base64EncodedString()]) + "\""
    }
}

/// A file of the page that isn't in the app.
struct PageMissing: Error, CustomStringConvertible {
    var name: String
    var reason: String

    var description: String { "the web remote's \(name) can't be read: \(reason)" }
}
