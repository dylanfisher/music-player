/// Sends the library profile to music-recommender unasked (ADR 0206): at launch, after a scan
/// that changed the library and when Rediscover opens or refreshes, each time only if the
/// profile changed since the last send. One send is out at a time; every ask made while one is
/// out is answered by one more send after it, which reads the profile then.
@MainActor
package final class ProfileSender {
    /// How an ask ended.
    package enum Outcome: Equatable, Sendable {
        /// The service's address or token isn't set, so nothing was sent.
        case notSet
        /// The profile is the one last sent, so nothing was sent.
        case unchanged
        case sent(ProfileReceipt)
        /// Reading or sending it failed, as text that names the address.
        case failed(String)
    }

    package typealias Send =
        @MainActor (LibraryProfile) async throws(RecommenderError) ->
        ProfileReceipt

    private let read: @MainActor () async throws -> LibraryProfile
    private let send: @MainActor () -> Send?
    /// The profile the service last kept from this sender; nil before the first send.
    private var lastSent: LibraryProfile?
    /// The newest send, and whether it is still waiting for the one before it to end, so an
    /// ask joins it instead of making another.
    private var tail: Task<Outcome, Never>?
    private var tailWaits = false
    private var tailForced = false

    /// `read` reads the profile off the main thread; `send` is the service's route as set now,
    /// nil while its address or token isn't set.
    package init(
        read: @escaping @MainActor () async throws -> LibraryProfile,
        send: @escaping @MainActor () -> Send?
    ) {
        self.read = read
        self.send = send
    }

    /// Sends the profile unless it is the one last sent, or, with `force`, even then: when
    /// another Mac may have sent its own since. The task answers once the send that covers
    /// this ask has ended.
    @discardableResult
    package func send(force: Bool = false) -> Task<Outcome, Never> {
        if let tail, tailWaits {
            tailForced = tailForced || force
            return tail
        }
        let before = tail
        tailWaits = true
        tailForced = force
        let task = Task {
            _ = await before?.value
            // Asks from here on wait for this send instead of joining it.
            tailWaits = false
            return await sendNow(force: tailForced)
        }
        tail = task
        return task
    }

    private func sendNow(force: Bool) async -> Outcome {
        guard let send = send() else { return .notSet }
        do {
            let profile = try await read()
            if !force, profile == lastSent { return .unchanged }
            let receipt = try await send(profile)
            lastSent = profile
            return .sent(receipt)
        } catch {
            return .failed("\(error)")
        }
    }
}
