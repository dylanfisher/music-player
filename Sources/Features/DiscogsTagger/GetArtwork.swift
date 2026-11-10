import AppKit
import Discogs
import DisplayText
import Foundation
import Library
import Metadata
import TagWriter

/// One album's files tagged with one release id, by file id, as Get Artwork covers them.
struct ArtworkGroup: Equatable {
    var title: String
    var releaseID: Int
    var fileIDs: [Int64]
}

extension TaggerModel {
    /// `album`'s files that `keeping` keeps, by the release id each is tagged with, or all of
    /// them by `written`, the release Apply wrote this session; a file with neither is left out.
    static func artworkGroups(
        _ album: DiscogsAlbum, written: Int? = nil, keeping: (Int64) -> Bool = { _ in true }
    ) -> [ArtworkGroup] {
        var groups: [ArtworkGroup] = []
        for track in album.tracks where keeping(track.fileID) {
            guard let id = written ?? track.releaseID.flatMap({ Int($0) }), id > 0 else { continue }
            if let index = groups.firstIndex(where: { $0.releaseID == id }) {
                groups[index].fileIDs.append(track.fileID)
            } else {
                groups.append(
                    ArtworkGroup(title: albumTitle(album), releaseID: id, fileIDs: [track.fileID]))
            }
        }
        return groups
    }

    /// What the window's Get Artwork covers: the albums listed and not rejected whose files
    /// are tagged with a release id, or that Apply wrote one to this session.
    var artworkGroups: [ArtworkGroup] {
        albums.filter { !$0.isRejected }.flatMap { album in
            Self.artworkGroups(album.matched, written: album.applied ? album.match.releaseID : nil)
        }
    }

    /// Reads the groups' paths, fetches each release's cover and works out which files get it.
    /// `progress` hears the albums done and how many there are.
    func planArtwork(
        _ groups: [ArtworkGroup], fill: CoverFill, progress: @escaping (Int, Int) -> Void
    ) async throws -> CoverPlan {
        let paths = try await effects.paths(groups.flatMap(\.fileIDs))
        let albums = groups.map { group in
            CoverAlbum(
                title: group.title, releaseID: group.releaseID,
                paths: group.fileIDs.compactMap { paths[$0] })
        }
        let cover = effects.cover
        let pixels = effects.pixels
        return await coverPlan(
            albums, fill: fill, cover: { await cover($0) }, pixels: { try await pixels($0) },
            progress: { progress($0, albums.count) })
    }

    /// "Get Artwork for 12 Albums", the button's title and the question's.
    static func artworkTitle(albums: Int) -> String {
        "Get Artwork for \(TaggerText.albums(albums))"
    }

    /// The question Get Artwork asks, with its count.
    static func artworkQuestion(albums: Int) -> (message: String, detail: String) {
        return (
            "\(artworkTitle(albums: albums))?",
            "Each album's files get its release's primary image from Discogs as their front"
                + " cover; their other pictures stay. The covers are fetched one release at a"
                + " time, as Discogs allows. Fill Missing gives it to files with no art or"
                + " smaller art, Replace to every file. Undo Tag Edit puts them back."
        )
    }

    /// "Getting covers: 3 of 20", and how far along.
    static func artworkProgress(_ done: Int, of total: Int) -> (text: String, fraction: Double) {
        (
            "Getting covers: \(number(done)) of \(number(total))",
            total == 0 ? 1 : Double(done) / Double(total)
        )
    }
}

extension DiscogsTagger {
    /// Get Discogs Artwork, in the library's track menu: Get Artwork for the albums of the
    /// tracks `ids`, their files tagged with a release id only, asking over `window`.
    /// `showing` hears how far the fetch is, nil once it's done.
    public func getArtwork(
        forTracks ids: [Int64], over window: NSWindow,
        showing: @escaping ((text: String, fraction: Double)?) -> Void
    ) {
        let albums = model.effects.albums
        Task {
            let wanted = Set(ids)
            let groups: [ArtworkGroup]
            do {
                groups = try await albums().flatMap {
                    TaggerModel.artworkGroups($0, keeping: wanted.contains)
                }
            } catch {
                return artworkAlert("The tracks' albums couldn't be read", ["\(error)"], window)
            }
            getArtwork(groups, over: window, showing: showing)
        }
    }

    /// Asks over `window` with the count, and Fill Missing or Replace, then fetches the covers
    /// and writes them as one undoable batch (ADR 0172). Without a token it says so.
    func getArtwork(
        _ groups: [ArtworkGroup], over window: NSWindow,
        showing: @escaping ((text: String, fraction: Double)?) -> Void
    ) {
        guard !groups.isEmpty else {
            return artworkAlert(
                "No album to get artwork for",
                ["Get Artwork covers albums whose files are tagged with a Discogs release id."],
                window)
        }
        guard model.hasToken() else {
            return artworkAlert(
                "Get Artwork needs a Discogs token", ["\(sentence("\(CoverProblem.needsToken)"))."],
                window)
        }
        askArtwork(TaggerModel.artworkQuestion(albums: groups.count), window) {
            [weak self] fill in
            guard let self, let fill else { return }
            Task {
                showing(TaggerModel.artworkProgress(0, of: groups.count))
                let plan: CoverPlan
                do {
                    plan = try await self.model.planArtwork(groups, fill: fill) { done, total in
                        showing(TaggerModel.artworkProgress(done, of: total))
                    }
                } catch {
                    showing(nil)
                    return self.artworkAlert(
                        "The albums' files couldn't be found", ["\(error)"], window)
                }
                showing(nil)
                guard !plan.edits.isEmpty else {
                    return self.artworkAlert(
                        "No file needed a cover",
                        plan.problems.isEmpty
                            ? ["Every file already has art at least as large as Discogs's."]
                            : plan.problems,
                        window)
                }
                self.write(plan.edits, window, { _ in }) { _ in }
                if !plan.problems.isEmpty {
                    self.artworkAlert("Some files got no cover", plan.problems, window)
                }
            }
        }
    }
}

/// Asks Get Artwork's question over `window` as a sheet: Fill Missing, Replace, or nil for
/// Cancel.
@MainActor
func askForArtwork(
    _ question: (message: String, detail: String), over window: NSWindow,
    answer: @escaping (CoverFill?) -> Void
) {
    let alert = NSAlert()
    alert.messageText = question.message
    alert.informativeText = question.detail
    alert.addButton(withTitle: "Fill Missing")
    alert.addButton(withTitle: "Replace")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { response in
        switch response {
        case .alertFirstButtonReturn: answer(.fillMissing)
        case .alertSecondButtonReturn: answer(.replace)
        default: answer(nil)
        }
    }
}

/// Shows `message` and the first few of `details` over `window`, as the tagger's alerts do.
@MainActor
func showProblems(_ message: String, _ details: [String], over window: NSWindow) {
    let shown = 8
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText =
        details.prefix(shown).joined(separator: "\n")
        + (details.count > shown ? "\n(\(details.count - shown) more not shown)" : "")
    alert.beginSheetModal(for: window)
}
