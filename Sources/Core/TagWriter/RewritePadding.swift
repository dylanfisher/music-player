/// The padding a tag rewritten past its room gets, so later edits fit and are written in place
/// (ADR 0108): 64 KiB, which holds lyrics or a small cover, or as much again as the new tag
/// when that's more, so a cover up to twice the size of the one there fits.
func rewritePaddingBytes(tagBytes: Int) -> Int {
    max(64 * 1024, tagBytes)
}
