/// How often and how recently each palette item was chosen or played, by its key, for ranking
/// by frecency. Sorted by key, each key once, at most `capacity` of them.
public struct VisitLog: SettingValue {
    public static let capacity = 1000

    public struct Visit: Codable, Equatable, Sendable {
        public var key: String
        public var count: Int
        /// Seconds since 1970.
        public var lastSeconds: Double

        public init(key: String, count: Int, lastSeconds: Double) {
            self.key = key
            self.count = count
            self.lastSeconds = lastSeconds
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case key, count, lastSeconds
        }

        public init(from decoder: any Decoder) throws {
            let container = try strictContainer(decoder, CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            count = try container.decode(Int.self, forKey: .count)
            lastSeconds = try container.decode(Double.self, forKey: .lastSeconds)
        }
    }

    public var visits: [Visit]

    public init(visits: [Visit]) {
        self.visits = visits
    }

    public init(from decoder: any Decoder) throws {
        visits = try decoder.singleValueContainer().decode([Visit].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(visits)
    }

    public static var typeName: String { "a list of visits (key, count, lastSeconds)" }
    public static var kind: SettingKind { .windowState }

    public func problem() -> String? {
        if visits.count > Self.capacity { return "more than \(Self.capacity) visits" }
        for (index, visit) in visits.enumerated() {
            if visit.count < 1 { return "[\(index)]: count \(visit.count) is under 1" }
            if index > 0, visits[index - 1].key >= visit.key {
                return "[\(index)]: \"\(visit.key)\" is out of order or listed twice"
            }
        }
        return nil
    }
}
