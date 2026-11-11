import LibraryBrowser
import NowPlaying

/// The bars' stars and the browser: a click on them rates the playing track through the
/// browser, as Get Info's do, and every rating the browser writes, from a table click, the menu,
/// a shortcut or Get Info, shows in them and in `alsoChanged` (ADR 0203). A sync shows through
/// the library's refresh instead.
@MainActor
func connectRatings(
    _ browser: LibraryBrowser, _ nowPlaying: NowPlayingBar, alsoChanged: @escaping () -> Void
) {
    browser.ratingsChanged = { [weak nowPlaying] rated in
        alsoChanged()
        nowPlaying?.ratingsChanged(rated?.stars) { rated?.includes($0) == true }
    }
    nowPlaying.ratingClicked = { [weak browser] stars, path in
        browser?.setRating(stars, paths: [path])
    }
}
