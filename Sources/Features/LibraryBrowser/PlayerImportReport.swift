import DisplayText
import Foundation
import Library
import Settings

/// The words for an import's preview and its report (ADR 0033). Every name and path came from
/// another program's file, so each is escaped as a playlist file's are (ADR 0032).
extension ImportPlan {
    /// The preview sheet's table: a row for each field the import changes, the others named in
    /// one line, and what it leaves out.
    var preview: ImportPreview {
        var rows: [ImportPreview.Row] = []
        var unchanged: [String] = []
        // A field that changes nothing is named in the "No change" line by its row's words up
        // to the comma, lowercased: "Last played, later" as "last played".
        func field(_ change: String, on changed: Int, _ count: String) {
            if changed > 0 {
                rows.append(ImportPreview.Row(change: change, count: count))
            } else {
                let name = change.prefix { $0 != "," }
                unchanged.append(name.prefix(1).lowercased() + name.dropFirst())
            }
        }
        field(
            "Play counts", on: tracksGainingPlays,
            "+\(number(playsAdded)) on \(tracks(tracksGainingPlays))")
        if library.player == .iTunes {
            field(
                "Skip counts", on: tracksGainingSkips,
                "+\(number(skipsAdded)) on \(tracks(tracksGainingSkips))")
        }
        field("Last played, later", on: lastPlayed, tracks(lastPlayed))
        field("Last plays, dated in Listening Stats", on: datedLastPlays, tracks(datedLastPlays))
        field("Date added, earlier", on: dateAdded, tracks(dateAdded))
        field(
            "Ratings, new", on: ratings,
            tracks(ratings)
                + (roundedRatings > 0
                    ? ", \(number(roundedRatings)) from a half star rounded up" : ""))
        field(TrackColumn.loved.title, on: loved, tracks(loved))
        field(
            "New playlists", on: playlists.count, number(playlists.count) + newPlaylistNotes)
        return ImportPreview(
            heading: "\(tracks(library.tracks.count)) read: \(number(matched)) in this library,"
                + " \(number(missedCount)) not"
                + (unreadFormat.isEmpty
                    ? "" : ", \(number(unreadFormat.count)) of them in a format not read yet"),
            rows: rows,
            unchanged: unchanged.isEmpty ? nil : "No change: " + unchanged.joined(separator: ", "),
            notes: previewNotes)
    }

    /// The tracks not matched to this library, whether or not their format is read.
    private var missedCount: Int { unmatched.count + unreadFormat.count }

    /// What the new playlists were in the other player.
    private var newPlaylistNotes: String {
        var notes: [String] = []
        let smart = playlists.filter { if case .smart = $0.kind { true } else { false } }.count
        if smart > 0 { notes.append("\(number(smart)) smart") }
        let wasSmart = playlists.filter(\.wasSmart).count
        if wasSmart > 0 { notes.append("\(number(wasSmart)) smart there, a list of tracks here") }
        return notes.isEmpty ? "" : " (" + notes.joined(separator: "; ") + ")"
    }

    /// What the import leaves as it is or leaves out, for the line under the preview's table.
    private var previewNotes: [String] {
        var notes: [String] = []
        if ratingsKept > 0 {
            notes.append("Ratings kept on \(tracks(ratingsKept)), rated differently here")
        }
        var skipped: [String] = []
        if !existingPlaylists.isEmpty {
            skipped.append("\(number(existingPlaylists.count)) with a name already used here")
        }
        if !unmappedPlaylists.isEmpty {
            skipped.append("\(number(unmappedPlaylists.count)) with rules that don't map")
        }
        if library.builtInPlaylists > 0 {
            skipped.append("\(number(library.builtInPlaylists)) built in or folders")
        }
        if !skipped.isEmpty {
            notes.append("Playlists skipped: " + skipped.joined(separator: ", "))
        }
        if mergedRows > 0 {
            notes.append("\(count(mergedRows, "row")) for a track already read, merged into it")
        }
        if library.tracksWithoutFiles > 0 {
            notes.append("\(tracks(library.tracksWithoutFiles)) with no file, left out")
        }
        let problems = library.problems.count + library.unlistedProblemCount
        if problems > 0 { notes.append("\(count(problems, "problem")) reading the library") }
        return notes
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
                + " \(tracks(tracksGainingPlays))"
        ]
        if ratings > 0 { parts.append(count(ratings, "rating")) }
        if loved > 0 { parts.append("\(number(loved)) loved") }
        parts.append(count(playlists.count, "playlist"))
        if missedCount > 0 { parts.append("\(number(missedCount)) unmatched") }
        return parts.joined(separator: " · ")
    }

    /// The details under the preview's counts and in the Problems window afterwards: what
    /// didn't match, wasn't made, or couldn't be read, each list cut at
    /// `PlaylistFile.maximumProblems` with a count of the rest.
    var detailLines: [String] { problems.map(\.line) }

    /// `detailLines` as the Problems window's rows, each miss listed with Locate… (ADR 0059).
    var problems: [Problem] {
        let source = terminalSafe(library.source)
        var rows: [Problem] = []
        func list(_ items: [String], _ what: String, fix: (String) -> Problem.Fix? = { _ in nil }) {
            let shown = PlaylistFile.maximumProblems
            rows += items.prefix(shown).map {
                Problem("\(source): \(what): \(terminalSafe($0))", fix: fix($0))
            }
            if items.count > shown {
                rows.append(Problem("\(source): \(number(items.count - shown)) more \(what)"))
            }
        }
        list(unmatched, "not in the library") { .locate(path: $0) }
        list(unreadFormat, "not in the library, a format this app doesn't read yet")
        list(existingPlaylists, "not made, a playlist has the name")
        list(
            unmappedPlaylists.map { "\($0.name) (\($0.reasons.joined(separator: "; ")))" },
            "smart playlist not made, its rules don't map")
        list(
            playlists.filter { $0.missing > 0 || $0.repeated > 0 }.map {
                "\($0.name): \(number($0.missing)) not in the library, \(number($0.repeated)) listed twice"
            }, "playlist entries left out")
        list(playlists.filter(\.wasSmart).map(\.name), "smart playlist made a list of its tracks")
        rows += library.problems.map { Problem("\(source): \(terminalSafe($0.description))") }
        if library.unlistedProblemCount > 0 {
            rows.append(
                Problem("\(source): \(count(library.unlistedProblemCount, "more problem"))"))
        }
        return rows
    }
}

/// The words for the column layout an import from Swinsian brings across (ADR 0061).
extension SwinsianColumns {
    /// "6 columns, sorted by Artist; 1 skipped".
    var previewLine: String {
        var line = count(columns.count, "column")
        if let sortColumn {
            line += ", sorted by \(sortColumn.title)" + (sortAscending ? "" : ", descending")
        }
        if !skipped.isEmpty { line += "; \(number(skipped.count)) skipped" }
        return line
    }

    /// What was skipped, under the preferences file's path. Each ID came from that file, so
    /// it's escaped.
    var detailLines: [String] {
        let source = terminalSafe(source)
        return skipped.map { "\(source): column layout: \(terminalSafe($0))" }
    }
}
