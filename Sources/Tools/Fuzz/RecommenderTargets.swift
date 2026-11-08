import Recommender

/// A job as music-recommender's API reports it, with every field the contract has.
private let job = """
    {"id": 42, "revision": 1093, "source": "upgrade", "format_policy": "flac",
    "release": {"release_id": 4242, "artist": "A", "title": "T", "year": 1999},
    "state": "staged", "failed_stage": null, "reason": null, "attempt": 1,
    "next_attempt_at": null, "progress": {"files_done": 1, "files_total": 2, "bytes_done": 3,
    "bytes_total": 4}, "candidate": {"peer": "p", "format": "flac", "bit_depth": 16,
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
        ].map { Array($0.utf8) }
    },
    prepare: { _ in
        { input in
            var read = false
            if (try? decodeReply(input, as: JobReply.self)) != nil { read = true }
            if let page = try? decodeReply(input, as: JobPage.self) {
                read = true
                var jobs = DownloadJobs()
                if (try? jobs.take(page)) != nil {
                    precondition(
                        jobs.after == page.jobs.last?.revision ?? 0,
                        "the paging went to \(jobs.after)")
                }
            }
            return read
        }
    })
