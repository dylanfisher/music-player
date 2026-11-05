import Foundation

/// A stretch of time plays are counted in: from `start` up to, not including, `end`, in whole
/// seconds since 1970 as `history.played_at` stores them.
public struct PlaySpan: Hashable, Sendable, Codable {
    public var start: Int64
    public var end: Int64

    public init(start: Int64, end: Int64) {
        precondition(start < end, "a span ends after it starts")
        self.start = start
        self.end = end
    }

    /// The span `interval` covers, its ends rounded down to whole seconds.
    public init(_ interval: DateInterval) {
        self.init(
            start: Int64(interval.start.timeIntervalSince1970.rounded(.down)),
            end: Int64(interval.end.timeIntervalSince1970.rounded(.down)))
    }

    public func contains(_ seconds: Int64) -> Bool { seconds >= start && seconds < end }

    /// The span as a saved source writes it: `<start>-<end>`.
    var text: String { "\(start)-\(end)" }

    /// Reads `text`; nil unless it's two whole numbers, the first smaller.
    init?(text: Substring) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int64(parts[0]), let end = Int64(parts[1]),
            parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
            start < end
        else { return nil }
        self.init(start: start, end: end)
    }

    /// How the timeline names the span: a day, or its first and last day.
    public func title(calendar: Calendar = .current) -> String {
        let format = DateIntervalFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateStyle = .medium
        format.timeStyle = .none
        let first = Date(timeIntervalSince1970: TimeInterval(start))
        // The last second in the span, so a day's span names one day.
        let last = Date(timeIntervalSince1970: TimeInterval(end - 1))
        return format.string(from: first, to: last)
    }
}
