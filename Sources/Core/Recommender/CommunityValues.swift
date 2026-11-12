import StrictKeys

/// The values the service's community sync stored for one Discogs release: its rating and
/// votes, have, want and what is for sale (`docs/api.md` there, section Community values).
/// A recommended album carries its row; a later library column can read the same row from
/// `/v1/community`.
package struct CommunityValues: Equatable, Sendable, Decodable {
    package enum Status: String, Equatable, Sendable, Decodable {
        /// The sync has its values.
        case fetched
        /// In the sync's queue and not fetched yet.
        case queued
        /// Given up on until the refresh; `values` holds an earlier fetch's, if it had one.
        case failed
        /// Discogs answered 404.
        case gone
        /// No profile sent it, so the sync doesn't know it.
        case notQueued = "not_queued"
    }

    package struct Values: Equatable, Sendable, Decodable {
        package var ratingAverage: Double
        package var ratingCount: Int
        package var have: Int
        package var want: Int
        package var numForSale: Int?
        package var lowestPrice: Double?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case ratingAverage = "rating_average"
            case ratingCount = "rating_count"
            case have, want
            case numForSale = "num_for_sale"
            case lowestPrice = "lowest_price"
        }

        init(
            ratingAverage: Double, ratingCount: Int, have: Int, want: Int, numForSale: Int?,
            lowestPrice: Double?
        ) {
            self.ratingAverage = ratingAverage
            self.ratingCount = ratingCount
            self.have = have
            self.want = want
            self.numForSale = numForSale
            self.lowestPrice = lowestPrice
        }

        package init(from decoder: any Decoder) throws {
            let container = try strictContainer(decoder, CodingKeys.self)
            ratingAverage = try container.decode(Double.self, forKey: .ratingAverage)
            ratingCount = try container.decode(Int.self, forKey: .ratingCount)
            have = try container.decode(Int.self, forKey: .have)
            want = try container.decode(Int.self, forKey: .want)
            numForSale = try container.decode(Int?.self, forKey: .numForSale)
            lowestPrice = try container.decode(Double?.self, forKey: .lowestPrice)
        }
    }

    package var releaseID: Int
    package var status: Status
    package var checkedAt: Int?
    package var values: Values?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case releaseID = "release_id"
        case status
        case checkedAt = "checked_at"
        case values
    }

    init(releaseID: Int, status: Status, checkedAt: Int?, values: Values?) {
        self.releaseID = releaseID
        self.status = status
        self.checkedAt = checkedAt
        self.values = values
    }

    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        releaseID = try container.decode(Int.self, forKey: .releaseID)
        status = try container.decode(Status.self, forKey: .status)
        checkedAt = try container.decode(Int?.self, forKey: .checkedAt)
        values = try container.decode(Values?.self, forKey: .values)
    }
}
