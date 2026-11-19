import Foundation

/// The words typed in a list's search field. A row passes when each word is in one of its
/// texts, ignoring case and accents, so "bjork 1997" finds "Björk - Homogenic (1997)". It
/// filters the rows a list has; it never changes what the list reads.
public struct ListFilter: Equatable, Sendable {
    let words: [String]

    public init(_ text: String) {
        words = text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// No words: every row passes.
    public var isEmpty: Bool { words.isEmpty }

    /// Whether each word is in one of `texts`. A word can't match across two texts, since none
    /// holds whitespace.
    public func matches(_ texts: [String]) -> Bool {
        words.allSatisfy { word in
            texts.contains {
                $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}
