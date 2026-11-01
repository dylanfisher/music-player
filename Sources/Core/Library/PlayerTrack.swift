/// What another player knows of one file.
public struct PlayerTrack: Equatable, Sendable {
    /// Absolute, in the Unicode form the player wrote.
    public var path: String
    var plays = 0
    var skips = 0
    /// Seconds since 1970.
    public var lastPlayedSeconds: Double?
    public var addedSeconds: Double?
    /// 1 to 5 stars; nil for none.
    public var rating: Int?
    /// The rating was a half star rounded up (ADR 0033).
    var ratingRounded = false
    public var loved = false

    init(path: String) { self.path = path }

    /// Takes in another row for the same path: counts add, and the latest last played, the
    /// earliest date added and the highest rating win.
    mutating func merge(_ other: PlayerTrack) {
        plays += other.plays
        skips += other.skips
        lastPlayedSeconds = later(lastPlayedSeconds, other.lastPlayedSeconds)
        addedSeconds = earlier(addedSeconds, other.addedSeconds)
        if (other.rating ?? 0) > (rating ?? 0) {
            ratingRounded = other.ratingRounded
        } else if other.rating == rating {
            ratingRounded = ratingRounded && other.ratingRounded
        }
        rating = [rating, other.rating].compactMap { $0 }.max()
        loved = loved || other.loved
    }
}

func later(_ a: Double?, _ b: Double?) -> Double? { [a, b].compactMap { $0 }.max() }
func earlier(_ a: Double?, _ b: Double?) -> Double? { [a, b].compactMap { $0 }.min() }
