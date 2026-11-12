import StrictKeys

/// What the service did with a profile it kept.
package struct ProfileReceipt: Equatable, Sendable, Decodable {
    package var albums: Int
    package var withReleaseID: Int
    /// Release ids that weren't in the community sync's queue before.
    package var queued: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ok, albums
        case withReleaseID = "with_release_id"
        case queued
    }
}

extension ProfileReceipt {
    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        albums = try container.decode(Int.self, forKey: .albums)
        withReleaseID = try container.decode(Int.self, forKey: .withReleaseID)
        queued = try container.decode(Int.self, forKey: .queued)
    }
}

extension RecommenderClient {
    /// Longest sending the profile takes: a body of a few MB over Wi-Fi, and the service's
    /// write of it before it answers.
    static let profileTimeoutSeconds = 60.0

    /// Sends `profile` as the one the service keeps, the bytes Export Library Profile… writes.
    package func sendProfile(_ profile: LibraryProfile) async throws(RecommenderError)
        -> ProfileReceipt
    {
        try await call(
            "/v1/profile", body: profile, as: ProfileReceipt.self,
            timeoutSeconds: Self.profileTimeoutSeconds)
    }
}
