import Discogs

/// What Get Info's Discogs tab says of the first of `releases` the files are from, once the
/// catalog was read: the release as the catalog has it, or why it isn't shown.
func discogsTabText(_ read: Result<ReleaseDetail?, any Error>, releases: Int) -> String {
    let others = releases - 1
    let note =
        others > 0
        ? "The first of the files' releases, and \(others) other release\(others == 1 ? "" : "s").\n\n"
        : ""
    switch read {
    case .success(let detail?): return note + detail.text
    case .success(nil): return note + "This release isn't in the local catalog."
    case .failure(CatalogError.missing): return "No Discogs catalog is imported."
    case .failure(let error): return "The Discogs catalog couldn't be read: \(error)"
    }
}
