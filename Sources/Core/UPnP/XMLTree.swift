import Foundation

/// An XML element as a description or a SOAP reply has it: the local name without its
/// namespace, its attributes, its own text, and its children.
struct XMLTree: Equatable {
    var name: String
    var attributes: [String: String] = [:]
    var text = ""
    var children: [XMLTree] = []

    /// The first child named `name`.
    func child(_ name: String) -> XMLTree? { children.first { $0.name == name } }

    /// The text of the first child named `name`, trimmed.
    func value(_ name: String) -> String? {
        child(name).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Most bytes a document may have.
    static let byteCap = 1024 * 1024
    /// Deepest nesting, most elements and most text in one element a document may have.
    static let depthCap = 32
    static let elementCap = 10_000
    static let textCap = 256 * 1024

    /// Parses `bytes` with `XMLParser`, external entities off and any DTD refused before the
    /// parser sees it, so neither an external entity nor an entity expansion runs.
    static func parse(_ bytes: [UInt8]) throws(XMLProblem) -> XMLTree {
        guard bytes.count <= byteCap else { throw .tooLarge(bytes: bytes.count) }
        // UPnP documents are UTF-8 and start with their XML declaration or root. Anything else
        // would have XMLParser guess at an encoding, or read past a NUL as libxml2 does.
        guard bytes.first == UInt8(ascii: "<"), !bytes.contains(0) else {
            throw .notUTF8XML("it has a NUL or a BOM, or doesn't start with <")
        }
        if let declared = declaredEncoding(bytes), declared.lowercased() != "utf-8" {
            throw .notUTF8XML("it declares the encoding \(declared)")
        }
        let upper = bytes.map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 0x20 : $0 }
        guard upper.firstRange(of: Array("<!DOCTYPE".utf8)) == nil,
            upper.firstRange(of: Array("<!ENTITY".utf8)) == nil
        else { throw .declaresEntities }
        let reader = TreeReader()
        let parser = XMLParser(data: Data(bytes))
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        let parsed = parser.parse()
        if let problem = reader.problem { throw problem }
        guard parsed, let root = reader.root else {
            throw .malformed(parser.parserError.map { "\($0.localizedDescription)" } ?? "no root")
        }
        return root
    }

    /// The `encoding` the XML declaration names, if there's a declaration and it names one.
    private static func declaredEncoding(_ bytes: [UInt8]) -> String? {
        guard bytes.starts(with: Array("<?xml".utf8)),
            let end = bytes.firstRange(of: Array("?>".utf8))
        else { return nil }
        let declaration = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
        guard let key = declaration.range(of: "encoding") else { return nil }
        let rest = declaration[key.upperBound...].drop { $0 == " " || $0 == "=" }
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return "" }
        return String(rest.dropFirst().prefix { $0 != quote })
    }
}

/// Every element of `bytes` with no children, in document order, as its local name and its
/// text untrimmed: what a renderer reads back from a document the app wrote.
func xmlLeaves(_ bytes: [UInt8]) throws(DescriptionProblem) -> [(
    name: String, text: String
)] {
    let root: XMLTree
    do throws(XMLProblem) {
        root = try XMLTree.parse(bytes)
    } catch {
        throw .unreadable("\(error)")
    }
    func leaves(_ tree: XMLTree) -> [(name: String, text: String)] {
        tree.children.isEmpty ? [(tree.name, tree.text)] : tree.children.flatMap(leaves)
    }
    return leaves(root)
}

/// Why a document wasn't read.
enum XMLProblem: Error, Equatable, CustomStringConvertible {
    case tooLarge(bytes: Int)
    case notUTF8XML(String)
    /// A DTD or an entity declaration, which no UPnP document has.
    case declaresEntities
    case tooDeep
    case tooManyElements
    case tooMuchText
    case malformed(String)

    var description: String {
        switch self {
        case .tooLarge(let bytes): "\(bytes) bytes is over the \(XMLTree.byteCap)-byte cap"
        case .notUTF8XML(let why): "it isn't UTF-8 XML: \(why)"
        case .declaresEntities: "it declares a DTD or entities"
        case .tooDeep: "it nests deeper than \(XMLTree.depthCap)"
        case .tooManyElements: "it has over \(XMLTree.elementCap) elements"
        case .tooMuchText: "an element has over \(XMLTree.textCap) bytes of text"
        case .malformed(let why): "it isn't well-formed XML: \(why)"
        }
    }
}

/// Builds the tree as the parser reports it, and stops it at the first cap.
private final class TreeReader: NSObject, XMLParserDelegate {
    var root: XMLTree?
    var problem: XMLProblem?
    private var open: [XMLTree] = []
    private var count = 0

    private func stop(_ parser: XMLParser, _ reason: XMLProblem) {
        problem = problem ?? reason
        parser.abortParsing()
    }

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        count += 1
        guard count <= XMLTree.elementCap else { return stop(parser, .tooManyElements) }
        guard open.count < XMLTree.depthCap else { return stop(parser, .tooDeep) }
        open.append(XMLTree(name: name, attributes: attributes))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !open.isEmpty else { return }
        guard open[open.count - 1].text.utf8.count + string.utf8.count <= XMLTree.textCap else {
            return stop(parser, .tooMuchText)
        }
        open[open.count - 1].text += string
    }

    func parser(
        _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        guard let done = open.popLast() else { return }
        if open.isEmpty {
            root = done
        } else {
            open[open.count - 1].children.append(done)
        }
    }

    func parser(
        _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
        publicID: String?, systemID: String?
    ) {
        stop(parser, .declaresEntities)
    }

    func parser(
        _ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?
    ) {
        stop(parser, .declaresEntities)
    }

    func parser(
        _ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?
    ) -> Data? {
        stop(parser, .declaresEntities)
        return nil
    }
}
