/// What the user said of a track with Like or Dislike. Like is the loved flag that imports and
/// smart rules read; a track has at most one opinion (ADR 0048).
public enum TrackOpinion: Sendable {
    case liked, disliked
}
