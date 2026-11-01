import Foundation
import Metadata

/// A field the tag editor can set or clear.
public enum TagEditField: String, CaseIterable, Sendable {
    case title, artist, album, albumArtist, genre, date, composer, comment
    case trackNumber, trackTotal, discNumber, discTotal
    /// "1" sets the flag; empty text or "0" clears it.
    case compilation

    /// The largest track or disc number every format holds: MP4 stores them in 16 bits.
    static let maximumNumber = Int(UInt16.max)
}

/// New art for a file, or none.
public enum ArtChange: Equatable, Sendable {
    /// A JPEG or PNG image, stored as the front cover.
    case replace(Data, mimeType: String)
    case remove
}

/// What one edit changes. Fields it doesn't name are left as they are in each file.
public struct TagEdit: Equatable, Sendable {
    /// The new text of each changed field. Empty text clears the field.
    public var values: [TagEditField: String]
    public var art: ArtChange?

    public init(values: [TagEditField: String] = [:], art: ArtChange? = nil) {
        self.values = values
        self.art = art
    }

    public var isEmpty: Bool { values.isEmpty && art == nil }

    /// `tags` with this edit's values. Throws for a value no format can hold as written, so the
    /// editor can show the problem before anything is written.
    public func applied(to tags: TrackTags) throws(TagValueError) -> TrackTags {
        var result = tags
        for (field, text) in values.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw TagValueError(field: field, text: text, detail: "can't hold a NUL character")
            }
            switch field {
            case .title: result.title = text.nilIfEmpty
            case .artist: result.artist = text.nilIfEmpty
            case .album: result.album = text.nilIfEmpty
            case .albumArtist: result.albumArtist = text.nilIfEmpty
            case .genre: result.genre = text.nilIfEmpty
            case .date: result.date = text.nilIfEmpty
            case .composer: result.composer = text.nilIfEmpty
            case .comment: result.comment = text.nilIfEmpty
            case .trackNumber: result.trackNumber = try number(field, text)
            case .trackTotal: result.trackTotal = try number(field, text)
            case .discNumber: result.discNumber = try number(field, text)
            case .discTotal: result.discTotal = try number(field, text)
            case .compilation:
                switch text {
                case "1": result.compilation = true
                case "", "0": result.compilation = false
                default:
                    throw TagValueError(field: field, text: text, detail: "isn't 1 or 0")
                }
            }
        }
        if case .replace(_, let mimeType) = art, !artMIMETypes.contains(mimeType) {
            throw TagValueError(
                field: nil, text: mimeType, detail: "art must be a JPEG or PNG image")
        }
        return result
    }
}

/// The image types every format the writer handles can label.
let artMIMETypes: Set<String> = [jpegMIMEType, pngMIMEType]

/// A value the edit can't write.
public struct TagValueError: Error, Equatable, CustomStringConvertible {
    /// Nil for the art.
    public var field: TagEditField?
    public var text: String
    public var detail: String

    public var description: String {
        "\(field?.rawValue ?? "art") \"\(text)\" \(detail)"
    }
}

/// Empty text clears; otherwise a whole number from 1 to `maximumNumber`.
private func number(_ field: TagEditField, _ text: String) throws(TagValueError) -> Int? {
    guard !text.isEmpty else { return nil }
    guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text),
        (1...TagEditField.maximumNumber).contains(value)
    else {
        throw TagValueError(
            field: field, text: text,
            detail: "isn't a whole number from 1 to \(TagEditField.maximumNumber)")
    }
    return value
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
