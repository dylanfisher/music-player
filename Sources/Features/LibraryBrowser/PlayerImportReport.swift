import DisplayText
import Foundation
import Library

/// The words for an import's preview and its report (ADR 0033). Every name and path came from
/// another program's file, so each is escaped as a playlist file's are (ADR 0032).
extension ImportPlan {
    /// One line per field, for the preview sheet.
    var previewLines: [String] {
        var lines = [
            "\(count(library.tracks.count, "track")) read: \(number(matched)) in this library,"
                + " \(number(unmatched.count)) not",
            "Play counts: +\(number(playsAdded)) on \(count(tracksGainingPlays, "track"))",
        ]
        if library.player == .iTunes {
            lines.append(
                "Skip counts: +\(number(skipsAdded)) on \(count(tracksGainingSkips, "track"))")
        }
        lines += [
            "Last played: later on \(count(lastPlayed, "track"))",
            "Date added: earlier on \(count(dateAdded, "track"))",
            "Ratings: \(count(ratings, "track")) rated"
                + (ratingsKept > 0
                    ? ", \(number(ratingsKept)) keep the rating they have here" : ""),
            "Loved: \(count(loved, "track"))",
            "Playlists: \(number(playlists.count)) new" + playlistNotes,
        ]
        if mergedRows > 0 {
            lines.append("\(count(mergedRows, "row")) for a track already read, merged into it")
        }
        if library.tracksWithoutFiles > 0 {
            lines.append("\(count(library.tracksWithoutFiles, "track")) with no file, left out")
        }
        let problems = library.problems.count + library.unlistedProblemCount
        if problems > 0 { lines.append("\(count(problems, "problem")) reading the library") }
        return lines
    }

    private var playlistNotes: String {
        var notes: [String] = []
        let smart = playlists.filter { if case .smart = $0.kind { true } else { false } }.count
        if smart > 0 { notes.append("\(number(smart)) smart") }
        let wasSmart = playlists.filter(\.wasSmart).count
        if wasSmart > 0 { notes.append("\(number(wasSmart)) smart there, a list of tracks here") }
        if !existingPlaylists.isEmpty {
            notes.append("\(number(existingPlaylists.count)) skipped, a playlist has the name")
        }
        if !unmappedPlaylists.isEmpty {
            notes.append("\(number(unmappedPlaylists.count)) skipped, rules that don't map")
        }
        if library.builtInPlaylists > 0 {
            notes.append("\(number(library.builtInPlaylists)) built in or folders, skipped")
        }
        return notes.isEmpty ? "" : " (" + notes.joined(separator: "; ") + ")"
    }

    /// The smart playlists whose rules don't map, with why.
    private var unmappedPlaylists: [(name: String, reasons: [String])] {
        library.playlists.compactMap {
            if case .unmapped(let reasons) = $0.kind { ($0.name, reasons) } else { nil }
        }
    }

    /// "Imported from Swinsian: +1,204 plays on 800 tracks · 12 ratings · 3 playlists".
    var summary: String {
        var parts = [
            "Imported from \(library.player.title): +\(number(playsAdded)) plays on"
                + " \(count(tracksGainingPlays, "track"))"
        ]
        if ratings > 0 { parts.append(count(ratings, "rating")) }
        if loved > 0 { parts.append("\(number(loved)) loved") }
        parts.append(count(playlists.count, "playlist"))
        if !unmatched.isEmpty { parts.append("\(number(unmatched.count)) unmatched") }
        return parts.joined(separator: " · ")
    }

    /// The details under the preview's counts and in the Problems window afterwards: what
    /// didn't match, wasn't made, or couldn't be read, each list cut at
    /// `PlaylistFile.maximumProblems` with a count of the rest.
    var detailLines: [String] {
        let source = terminalSafe(library.source)
        var lines: [String] = []
        func list(_ items: [String], _ what: String) {
            let shown = PlaylistFile.maximumProblems
            lines += items.prefix(shown).map { "\(source): \(what): \(terminalSafe($0))" }
            if items.count > shown {
                lines.append("\(source): \(number(items.count - shown)) more \(what)")
            }
        }
        list(unmatched, "not in the library")
        list(existingPlaylists, "not made, a playlist has the name")
        list(
            unmappedPlaylists.map { "\($0.name) (\($0.reasons.joined(separator: "; ")))" },
            "smart playlist not made, its rules don't map")
        list(
            playlists.filter { $0.missing > 0 || $0.repeated > 0 }.map {
                "\($0.name): \(number($0.missing)) not in the library, \(number($0.repeated)) listed twice"
            }, "playlist entries left out")
        list(playlists.filter(\.wasSmart).map(\.name), "smart playlist made a list of its tracks")
        lines += library.problems.map { "\(source): \(terminalSafe($0.description))" }
        if library.unlistedProblemCount > 0 {
            lines.append("\(source): \(count(library.unlistedProblemCount, "more problem"))")
        }
        return lines
    }
}
