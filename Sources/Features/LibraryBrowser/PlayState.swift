import Foundation
import Library
import Log
import Playback
import Settings

private let logger = moduleLogger()

/// A play state's window as this Mac's index has it: the source, the source its track was
/// played from, the selected track and the first visible one.
struct ResumedWindow {
    var source: BrowserSource?
    var from: TrackFilter?
    var selected: Int64?
    var top: Int64?
}

/// The play state the config file carries across quits and between Macs (ADR 0095). Each read
/// is a lookup or two in the main thread's index, which touches no music file.
extension LibraryBrowser {
    /// Where playback and the window are, as the config file keeps them. `playing` is the
    /// loaded track's path and how far into it, nil when none is. Nil when the index couldn't
    /// be read, which is logged, so nothing saved is replaced by less.
    public func resumePoint(playing: (path: String, seconds: Double)?) -> ResumePoint? {
        do {
            var point = ResumePoint(source: try index.sharedName(of: model.filter.source))
            if let playing, let id = trackID(path: playing.path),
                let track = try index.sharedName(ofTrack: id)
            {
                point.track = track
                point.seconds = playing.seconds
                point.from = try index.sharedName(of: model.playSource?.source)
            }
            guard !showsTimeline else { return point }
            if let id = rowID(at: table.table.selectedRow) {
                point.selected = try index.sharedName(ofTrack: id)
            }
            if let top = listPlace().scroll?.id { point.top = try index.sharedName(ofTrack: top) }
            return point
        } catch {
            logger.error("couldn't read the play state from the library: \(error)")
            return nil
        }
    }

    /// `resume`'s window on this Mac. What it can't find is left out and logged.
    func resumedWindow(_ resume: ResumePoint) -> ResumedWindow {
        do {
            return ResumedWindow(
                source: try index.source(sharedName: resume.source),
                from: resume.track == nil
                    ? nil : TrackFilter(source: try index.source(sharedName: resume.from)),
                selected: try resume.selected.flatMap(index.trackID(sharedName:)),
                top: try resume.top.flatMap(index.trackID(sharedName:)))
        } catch {
            logger.error("couldn't read the saved play state's window from the library: \(error)")
            return ResumedWindow()
        }
    }

    /// Selects the resumed track and puts its first visible row at the top, in the source the
    /// load showed.
    func show(_ resumed: ResumedWindow) async {
        guard !showsTimeline, resumed.selected != nil || resumed.top != nil else { return }
        await show(
            WindowPlace(
                filter: model.filter, selection: Set([resumed.selected].compactMap { $0 }),
                scroll: resumed.top.map { WindowPlace.Scroll(id: $0, offset: 0) }))
    }

    /// The track `resume` names, paused at its seconds, in the list of the source it was played
    /// from as its queue, with its length from the index. Nil when it names none, or when this
    /// Mac's library doesn't have it, which is logged. The queue is read off the main actor.
    public func resumedPlayback(_ resume: ResumePoint) async -> (
        spot: PlaybackSpot, durationSeconds: Double
    )? {
        guard let name = resume.track else { return nil }
        do {
            guard let id = try index.trackID(sharedName: name),
                let row = try index.rows(ids: [id]).first
            else {
                logger.notice(
                    "the saved track \(name) isn't in the library here; starting without it")
                return nil
            }
            let from = model.resumedFrom?.source
            var ids = [id]
            if from?.listsPlays != true {
                let sort = model.queueSort(for: from)
                let listed = try await reader.trackIDs(
                    TrackFilter(source: from, groupByAlbumArtist: model.filter.groupByAlbumArtist),
                    sortedBy: sort.column, ascending: sort.ascending)
                if listed.contains(id) {
                    ids = listed
                } else {
                    logger.notice(
                        "\(name) has left the source it was played from; queueing it alone")
                }
            }
            guard
                let request = try await BrowserModel.request(
                    ids: ids, first: ids.firstIndex(of: id) ?? 0, reader: reader)
            else { return nil }
            return (
                PlaybackSpot(
                    queue: request.urls, index: request.first, seconds: resume.seconds,
                    status: .paused),
                row.durationSeconds
            )
        } catch {
            logger.error("couldn't read the saved track's queue: \(error)")
            return nil
        }
    }
}
