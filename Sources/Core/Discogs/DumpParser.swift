import Foundation

/// One record of a dump, as `DumpParser` builds it.
enum DumpRecord: Sendable {
    case label(CatalogLabel)
    case artist(CatalogArtist)
    case master(CatalogMaster)
    case release(CatalogRelease)
}

/// Builds one record per top-level element of a dump as `XMLParser` reads it, and hands each
/// to `emit` (ADR 0130). It keeps only what the catalog stores: the subtrees it has no use for,
/// such as videos and profiles, are passed over without their text. Every element but a
/// record's id is optional, as the dumps leave out what a record doesn't have. Belongs to the
/// thread that parses.
final class DumpParser: NSObject, XMLParserDelegate {
    /// Records parsed between two checks for a stop.
    static let recordsPerStopCheck = 256
    /// The identifier type the barcodes are, the only identifiers kept.
    static let barcodeType = "Barcode"

    private let kind: DumpKind
    private let record: DumpElement
    private let skipped: Set<DumpElement>
    private let file: String
    private let emit: (DumpRecord) throws -> Void
    /// Why parsing stopped early: a malformed record, a stop, or an error from `emit`.
    private(set) var failure: (any Error)?
    private(set) var records = 0
    private weak var parser: XMLParser?
    /// The lines of the file before the batch being parsed.
    private var lineOffset = 0

    /// The open elements, the root's first; nil for a name the parser doesn't look at.
    private var stack: [DumpElement?] = []
    private var text = ""
    /// The depth of the open element whose subtree is passed over, if any.
    private var skippedDepth: Int?

    // The record being built, and its open parts.
    private var id: Int?
    private var name = ""
    private var release = CatalogRelease(id: 0, title: "")
    private var master = CatalogMaster(id: 0, title: "")
    private var nameVariations: [String] = []
    private var artist = ArtistFields()
    /// The open tracks: an index track's sub-track above it.
    private var tracks: [CatalogTrack] = []

    /// An artist element's children, for a credit or a role.
    private struct ArtistFields {
        var id: Int?
        var name = ""
        var nameVariation: String?
        var join: String?
        var role: String?
        var tracks: String?
    }

    init(kind: DumpKind, file: String, emit: @escaping (DumpRecord) throws -> Void) {
        self.kind = kind
        record = DumpElement(record: kind)
        skipped = DumpElement.skipped(in: kind)
        self.file = file
        self.emit = emit
    }

    /// Parses one batch of whole records, whose first is on `firstLine` of the file, in an
    /// autorelease pool of its own, and returns whether it got to its end.
    func parse(_ document: Data, firstLine: Int) -> Bool {
        autoreleasepool {
            let parser = XMLParser(data: document)
            self.parser = parser
            lineOffset = firstLine - 1
            parser.delegate = self
            parser.shouldResolveExternalEntities = false
            return parser.parse() && failure == nil
        }
    }

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        let element = DumpElement(rawValue: name)
        stack.append(element)
        text = ""
        guard skippedDepth == nil else { return }
        if stack.count == 2 {
            startRecord(element, name: name, attributes)
            return
        }
        guard let element else { return }
        if skipped.contains(element) {
            skippedDepth = stack.count
            return
        }
        func attribute(_ key: DumpAttribute) -> String? { attributes[key.rawValue] }
        switch (kind, element) {
        case (_, .artist): artist = ArtistFields()
        case (.releases, .masterID):
            release.isMainRelease = attribute(.isMainRelease).flatMap { Bool($0) } ?? false
        case (.releases, .label) where parent == .labels:
            release.labels.append(
                CatalogRelease.Label(
                    id: attribute(.id).flatMap { Int($0) }, name: attribute(.name) ?? "",
                    catalogNumber: nonEmpty(attribute(.catno))))
        case (.releases, .format) where parent == .formats:
            release.formats.append(
                CatalogRelease.Format(
                    name: attribute(.name) ?? "", quantity: attribute(.qty).flatMap { Int($0) },
                    text: nonEmpty(attribute(.text)), descriptions: []))
        case (.releases, .identifier) where attribute(.type) == Self.barcodeType:
            if let value = nonEmpty(attribute(.value)) { release.barcodes.append(value) }
        case (.releases, .track):
            tracks.append(CatalogTrack(kind: .track, position: nil, title: ""))
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if skippedDepth == nil { text += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        defer {
            stack.removeLast()
            text = ""
        }
        if let depth = skippedDepth {
            if depth == stack.count { skippedDepth = nil }
            return
        }
        if stack.count == 2 {
            endRecord()
            return
        }
        guard let element = stack.last ?? nil else { return }
        let parent = parent
        // A record's own children are at depth 3; an artist credit's are deeper.
        if parent == .artist, stack.count > 3 {
            endArtistField(element)
            return
        }
        switch kind {
        case .labels, .artists: endNamedRecordField(element, parent: parent)
        case .masters: endMasterField(element, parent: parent)
        case .releases: endReleaseField(element, parent: parent)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: any Error) {
        if failure == nil {
            failure = CatalogImportError.malformed(
                file, line: lineOffset + parser.lineNumber, (error as NSError).localizedDescription)
        }
    }

    /// The line of the file the parser is on.
    private var line: Int { lineOffset + (parser?.lineNumber ?? 0) }

    /// The open element's parent.
    private var parent: DumpElement? { stack.count > 1 ? stack[stack.count - 2] : nil }

    private func startRecord(
        _ element: DumpElement?, name elementName: String, _ attributes: [String: String]
    ) {
        guard element == record else {
            return stop(
                .malformed(file, line: line, "a <\(elementName)> in \(kind)"))
        }
        id = attributes[DumpAttribute.id.rawValue].flatMap { Int($0) }
        name = ""
        nameVariations = []
        tracks = []
        switch kind {
        case .releases: release = CatalogRelease(id: id ?? 0, title: "")
        case .masters: master = CatalogMaster(id: id ?? 0, title: "")
        case .labels, .artists: break
        }
    }

    private func endRecord() {
        guard let id else {
            return stop(
                .malformed(file, line: line, "a <\(record.rawValue)> with no id"))
        }
        let built: DumpRecord =
            switch kind {
            case .labels: .label(CatalogLabel(id: id, name: name))
            case .artists:
                .artist(CatalogArtist(id: id, name: name, nameVariations: nameVariations))
            case .masters: .master(master)
            case .releases: .release(release)
            }
        do {
            try emit(built)
        } catch {
            failure = error
            parser?.abortParsing()
            return
        }
        records += 1
        if records % Self.recordsPerStopCheck == 0, Task.isCancelled { stop(.stopped) }
    }

    private func stop(_ error: CatalogImportError) {
        if failure == nil { failure = error }
        parser?.abortParsing()
    }

    private func endArtistField(_ element: DumpElement) {
        switch element {
        case .id: artist.id = Int(trimmed(text))
        case .name: artist.name = trimmed(text)
        case .anv: artist.nameVariation = nonEmpty(text)
        case .join: artist.join = nonEmpty(text)
        case .role: artist.role = nonEmpty(text)
        case .tracks: artist.tracks = nonEmpty(text)
        default: break
        }
    }

    /// An artist element ended: a credit for the record or the open track.
    private func endArtist(inList list: DumpElement?) {
        let credit = CatalogArtistCredit(
            id: artist.id, name: artist.name, nameVariation: artist.nameVariation,
            join: artist.join)
        let role = CatalogCredit(
            id: artist.id, name: artist.name, nameVariation: artist.nameVariation,
            role: artist.role ?? "", tracks: artist.tracks)
        switch (kind, list, tracks.isEmpty) {
        case (.masters, .artists, _): master.artists.append(credit)
        case (.releases, .artists, true): release.artists.append(credit)
        case (.releases, .artists, false): tracks[tracks.count - 1].artists.append(credit)
        case (.releases, .extraartists, true): release.credits.append(role)
        case (.releases, .extraartists, false): tracks[tracks.count - 1].credits.append(role)
        default: break
        }
    }

    /// A label's or an artist's field: their ids are elements, not attributes.
    private func endNamedRecordField(_ element: DumpElement, parent: DumpElement?) {
        switch (parent, element) {
        case (_, .id) where stack.count == 3: id = Int(trimmed(text))
        case (_, .name) where stack.count == 3: name = trimmed(text)
        case (.namevariations, .name):
            if let variation = nonEmpty(text) { nameVariations.append(variation) }
        default: break
        }
    }

    private func endMasterField(_ element: DumpElement, parent: DumpElement?) {
        switch (parent, element) {
        case (.master, .mainRelease): master.mainReleaseID = Int(trimmed(text))
        case (.master, .title): master.title = trimmed(text)
        case (.master, .year): master.year = Int(trimmed(text)).flatMap { $0 > 0 ? $0 : nil }
        case (.artists, .artist): endArtist(inList: parent)
        case (.genres, .genre): nonEmpty(text).map { master.genres.append($0) }
        case (.styles, .style): nonEmpty(text).map { master.styles.append($0) }
        default: break
        }
    }

    private func endReleaseField(_ element: DumpElement, parent: DumpElement?) {
        switch (parent, element) {
        case (.release, .title): release.title = trimmed(text)
        case (.release, .country): release.country = nonEmpty(text)
        case (.release, .released): release.released = nonEmpty(text)
        // The dumps write a release without a master as master 0.
        case (.release, .masterID):
            release.masterID = Int(trimmed(text)).flatMap { $0 > 0 ? $0 : nil }
        case (_, .artist): endArtist(inList: parent)
        case (.genres, .genre): nonEmpty(text).map { release.genres.append($0) }
        case (.styles, .style): nonEmpty(text).map { release.styles.append($0) }
        case (.descriptions, .description):
            if let description = nonEmpty(text), !release.formats.isEmpty {
                release.formats[release.formats.count - 1].descriptions.append(description)
            }
        case (.track, .position): tracks[tracks.count - 1].position = nonEmpty(text)
        case (.track, .title): tracks[tracks.count - 1].title = trimmed(text)
        case (.track, .duration):
            tracks[tracks.count - 1].durationSeconds = CatalogTrack.seconds(trimmed(text))
        case (_, .track): endTrack()
        default: break
        }
    }

    /// A track element ended: it's an index track when it has sub-tracks, a heading when it
    /// has no position and no duration, and a track otherwise.
    private func endTrack() {
        var track = tracks.removeLast()
        if !track.subTracks.isEmpty {
            track.kind = .index
        } else if track.position == nil, track.durationSeconds == nil {
            track.kind = .heading
        }
        if tracks.isEmpty {
            release.tracks.append(track)
        } else {
            tracks[tracks.count - 1].subTracks.append(track)
        }
    }
}

private func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func nonEmpty(_ text: String?) -> String? {
    guard let text else { return nil }
    let trimmed = trimmed(text)
    return trimmed.isEmpty ? nil : trimmed
}
