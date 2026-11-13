import Library
import LocalNetwork
import Recommender

/// A job as music-recommender's API reports it, with every field the contract has.
private let job = """
    {"id": 42, "revision": 1093, "source": "upgrade", "format_policy": "flac",
    "release": {"release_id": 4242, "artist": "A", "title": "T", "year": 1999},
    "state": "staged", "failed_stage": null, "reason": null, "attempt": 1,
    "next_attempt_at": null, "progress": {"files_done": 1, "files_total": 2, "bytes_done": 3,
    "bytes_total": 4}, "search": {"query": "a t", "query_number": 1, "query_count": 2,
    "peers": 14, "files": 389, "started_at": 1794060030}, "candidate": {"peer": "p", "format": "flac", "bit_depth": 16,
    "sample_rate": 44100, "bitrate": null, "variable_bitrate": null, "file_count": 2,
    "bytes": 7, "tracklist": 0}, "files": [{"name": "1.flac", "size": 3, "position": "1"},
    {"name": "x.jpg", "size": 4, "position": null}], "staged_path": "job-42",
    "tagging": {"status": "discrepancy", "reasons": ["r"]}, "lease": null,
    "review": {"machine": "M", "expires_at": 1794150000},
    "upgrade": {"current_quality": "MP3 320", "old_paths": ["library/a.mp3"]},
    "cleanup_pending": false, "created_at": 1, "updated_at": 2}
    """

/// music-recommender's replies: a job and a page of the job list,
/// which is taken into a fresh copy of the jobs as the client takes it.
let recommenderReply = FuzzTarget(
    name: "recommender-reply",
    summary: "music-recommender's replies: a job and a page of the job list",
    seedFormats: [],
    tokens: jsonTokens + ["9223372036854775808", "\"ok\": false", "\"error\""],
    madeSeeds: { _, _ in
        [
            #"{"ok": false, "error": {"code": "claimed", "message": "m", "machine": "M", "expires_at": 5}}"#,
            #"{"ok": true, "job": \#(job)}"#,
            #"{"ok": true, "epoch": "e", "revision": 1093, "reset": true, "more": false, "jobs": [\#(job)]}"#,
            #"{"ok": true, "enabled": true, "off_reason": null, "format_policies": ["flac"], "default_format_policy": "flac", "staging_dir_name": "staging", "slskd_url": "http://127.0.0.1:5030"}"#,
        ].map { Array($0.utf8) }
    },
    prepare: { _ in
        { input in
            var read = false
            // Most inputs aren't a reply of any kind; only one that decodes is checked.
            if (try? decodeReply(input, as: JobReply.self)) != nil { read = true }
            // As above, for the downloads config.
            if let config = try? decodeReply(input, as: DownloadsConfig.self) {
                read = true
                _ = config.slskdPage(reachedAt: .v4([192, 168, 1, 20]))
            }
            // As above, for a page of jobs.
            if let page = try? decodeReply(input, as: JobPage.self) {
                read = true
                var jobs = DownloadJobs()
                // A page the jobs refuse is a normal input here; only one they take is checked.
                if (try? jobs.take(page)) != nil {
                    precondition(
                        jobs.after == page.jobs.last?.revision ?? 0,
                        "the paging went to \(jobs.after)")
                }
            }
            return read
        }
    })

/// A day of Rediscover with every field the contract has, an untagged album and a thread.
private let rediscoverDay = """
    {"ok": true, "rediscover": {"day": "2026-11-12", "computed_at": 1800000000,
    "albums_considered": 6541}, "albums": [{"id": "r4242", "key": "a812", "artist": "A",
    "title": "T", "release_id": 4242, "year": 1997, "label": {"id": 30, "name": "L"},
    "styles": [{"id": 2, "name": "S"}], "plays": 31, "skips": 2, "last_played": 1693000000,
    "score": 0.92, "community": {"release_id": 4242, "status": "fetched",
    "checked_at": 1794060000, "values": {"rating_average": 4.4, "rating_count": 310,
    "have": 5120, "want": 1400, "num_for_sale": 12, "lowest_price": 9.5}}, "reasons": [
    {"kind": "credit", "words": "w", "keys": ["a90"], "artist": {"id": 21, "name": "D"},
    "role": "Engineer", "label": null}]}, {"id": "k3f9", "key": "a77", "artist": "B",
    "title": "U", "release_id": null, "year": null, "label": null, "styles": [], "plays": 0,
    "skips": 0, "last_played": null, "score": 0.61, "community": null, "reasons": [
    {"kind": "never_played", "words": "w", "keys": [], "artist": null, "role": null,
    "label": null}]}], "threads": [{"kind": "label", "words": "w", "ids": ["r4242", "k3f9"],
    "artist": null, "label": {"id": 30, "name": "L"}}]}
    """

/// music-recommender's Rediscover replies: a day, whose keys are read back as album ids as
/// the browser reads them, and Not Now's two answers.
let rediscoverReply = FuzzTarget(
    name: "rediscover-reply",
    summary: "music-recommender's Rediscover replies: a day and Not Now's answers",
    seedFormats: [],
    tokens: jsonTokens + ["\"a0\"", "\"a-1\"", "\"a9223372036854775808\"", "\"kind\""],
    madeSeeds: { _, _ in
        [
            rediscoverDay, #"{"ok": true, "until": 1802592000}"#,
            #"{"ok": true, "removed": false}"#,
            #"{"ok": false, "error": {"code": "no_profile", "message": "m"}}"#,
        ].map { Array($0.utf8) }
    },
    prepare: { _ in
        { input in
            var read = false
            // Most inputs aren't a reply of any kind; only one that decodes is checked.
            if let day = try? decodeReply(input, as: RediscoverDay.self) {
                read = true
                for album in day.albums {
                    if let id = albumID(profileKey: album.key) {
                        precondition(id > 0 && profileKey(albumID: id) == album.key, "\(album.key)")
                    }
                }
            }
            // As above, for Not Now's answers.
            if (try? decodeReply(input, as: NotNowReply.self)) != nil { read = true }
            // As above.
            if (try? decodeReply(input, as: UndoNotNowReply.self)) != nil { read = true }
            return read
        }
    })
