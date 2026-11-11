import StrictKeys

/// A download job as the service reports it, whole, as it is now. Times are seconds since 1970.
package struct DownloadJob: Equatable, Sendable, Decodable {
    /// How the job was made.
    package enum Source: String, Equatable, Sendable, Codable {
        case manual, upgrade, recommendation
    }

    /// The step a `failed` job failed at.
    package enum FailedStage: String, Equatable, Sendable, Codable {
        case search, download, stage, tag, move, delete, carry
    }

    /// The release, from the snapshot it was made with.
    package struct Release: Equatable, Sendable, Decodable {
        package var releaseID: Int
        package var artist: String
        package var title: String
        package var year: Int?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case releaseID = "release_id"
            case artist, title, year
        }

        init(releaseID: Int, artist: String, title: String, year: Int?) {
            self.releaseID = releaseID
            self.artist = artist
            self.title = title
            self.year = year
        }

        package init(from decoder: any Decoder) throws {
            let container = try strictContainer(decoder, CodingKeys.self)
            releaseID = try container.decode(Int.self, forKey: .releaseID)
            artist = try container.decode(String.self, forKey: .artist)
            title = try container.decode(String.self, forKey: .title)
            year = try container.decode(Int?.self, forKey: .year)
        }
    }

    /// With `downloading`, what slskd has received; with `downloaded`, what the copy into
    /// staging has copied, nil until the copy starts.
    package struct Progress: Equatable, Sendable, Decodable {
        package var filesDone: Int
        package var filesTotal: Int
        package var bytesDone: Int
        package var bytesTotal: Int

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case filesDone = "files_done"
            case filesTotal = "files_total"
            case bytesDone = "bytes_done"
            case bytesTotal = "bytes_total"
        }

        init(filesDone: Int, filesTotal: Int, bytesDone: Int, bytesTotal: Int) {
            self.filesDone = filesDone
            self.filesTotal = filesTotal
            self.bytesDone = bytesDone
            self.bytesTotal = bytesTotal
        }

        package init(from decoder: any Decoder) throws {
            let container = try strictContainer(decoder, CodingKeys.self)
            filesDone = try container.decode(Int.self, forKey: .filesDone)
            filesTotal = try container.decode(Int.self, forKey: .filesTotal)
            bytesDone = try container.decode(Int.self, forKey: .bytesDone)
            bytesTotal = try container.decode(Int.self, forKey: .bytesTotal)
        }
    }

    /// A `searching` job's query running now, once its first has started.
    package struct Search: Equatable, Sendable, Decodable {
        /// The search text sent to Soulseek.
        package var query: String
        /// Which of the attempt's queries it is, from 1, of `queryCount`, 1 or 2.
        package var queryNumber: Int
        package var queryCount: Int
        /// The peers that have answered this query so far, and the files in their answers.
        package var peers: Int
        package var files: Int
        package var startedAt: Int

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case query
            case queryNumber = "query_number"
            case queryCount = "query_count"
            case peers, files
            case startedAt = "started_at"
        }

        init(
            query: String, queryNumber: Int, queryCount: Int, peers: Int, files: Int,
            startedAt: Int
        ) {
            self.query = query
            self.queryNumber = queryNumber
            self.queryCount = queryCount
            self.peers = peers
            self.files = files
            self.startedAt = startedAt
        }

        package init(from decoder: any Decoder) throws {
            let container = try strictContainer(decoder, CodingKeys.self)
            query = try container.decode(String.self, forKey: .query)
            queryNumber = try container.decode(Int.self, forKey: .queryNumber)
            queryCount = try container.decode(Int.self, forKey: .queryCount)
            peers = try container.decode(Int.self, forKey: .peers)
            files = try container.decode(Int.self, forKey: .files)
            startedAt = try container.decode(Int.self, forKey: .startedAt)
        }
    }

    /// The Soulseek folder chosen, as its peer reported it.
    package struct Candidate: Equatable, Sendable, Decodable {
        package enum Format: String, Equatable, Sendable, Decodable {
            case flac, alac, mp3, ogg, opus, wav, ape, wv
        }

        /// The Soulseek user.
        package var peer: String
        package var format: Format
        package var bitDepth: Int?
        package var sampleRateHz: Int?
        package var bitrateKbps: Int?
        package var variableBitrate: Bool?
        package var fileCount: Int
        package var bytes: Int
        /// The index into the snapshot's `tracklists` the files matched.
        var tracklist: Int

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case peer, format
            case bitDepth = "bit_depth"
            case sampleRateHz = "sample_rate"
            case bitrateKbps = "bitrate"
            case variableBitrate = "variable_bitrate"
            case fileCount = "file_count"
            case bytes, tracklist
        }

        package init(from decoder: any Decoder) throws {
            let container = try strictContainer(decoder, CodingKeys.self)
            peer = try container.decode(String.self, forKey: .peer)
            format = try container.decode(Format.self, forKey: .format)
            bitDepth = try container.decode(Int?.self, forKey: .bitDepth)
            sampleRateHz = try container.decode(Int?.self, forKey: .sampleRateHz)
            bitrateKbps = try container.decode(Int?.self, forKey: .bitrateKbps)
            variableBitrate = try container.decode(Bool?.self, forKey: .variableBitrate)
            fileCount = try container.decode(Int.self, forKey: .fileCount)
            bytes = try container.decode(Int.self, forKey: .bytes)
            tracklist = try container.decode(Int.self, forKey: .tracklist)
        }
    }

    /// One of the job's files: until `staged` the remote file's name, from then on its path
    /// under `stagedPath`, `/`-separated.
    package struct File: Equatable, Sendable, Decodable {
        package var name: String
        package var sizeBytes: Int
        /// The matched track's position in the snapshot's tracklist `candidate.tracklist`;
        /// nil for an extra file.
        package var position: String?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case name
            case sizeBytes = "size"
            case position
        }

        init(name: String, sizeBytes: Int, position: String?) {
            self.name = name
            self.sizeBytes = sizeBytes
            self.position = position
        }

        package init(from decoder: any Decoder) throws {
            let container = try strictContainer(decoder, CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            sizeBytes = try container.decode(Int.self, forKey: .sizeBytes)
            position = try container.decode(String?.self, forKey: .position)
        }
    }

    /// What the player last reported of its tag run.
    package struct Tagging: Equatable, Sendable, Decodable {
        package enum Status: String, Equatable, Sendable, Codable {
            case none, running, clean, discrepancy, error
        }

        package var status: Status
        /// Empty unless `discrepancy` or `error`.
        package var reasons: [String]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case status, reasons
        }

        package init(status: Status, reasons: [String]) {
            self.status = status
            self.reasons = reasons
        }

        package init(from decoder: any Decoder) throws {
            let container = try strictContainer(decoder, CodingKeys.self)
            status = try container.decode(Status.self, forKey: .status)
            reasons = try container.decode([String].self, forKey: .reasons)
        }
    }

    /// A live tagging lease or review claim: whose, and until when.
    package struct Hold: Equatable, Sendable, Decodable {
        package var machine: String
        var expiresAt: Int

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case machine
            case expiresAt = "expires_at"
        }

        init(machine: String, expiresAt: Int) {
            self.machine = machine
            self.expiresAt = expiresAt
        }

        package init(from decoder: any Decoder) throws {
            let container = try strictContainer(decoder, CodingKeys.self)
            machine = try container.decode(String.self, forKey: .machine)
            expiresAt = try container.decode(Int.self, forKey: .expiresAt)
        }
    }

    /// What an upgrade replaces: the old album's quality, for the window, and its files,
    /// relative to the library share, so they resolve on any Mac and after an index rebuild.
    package struct Upgrade: Equatable, Sendable, Codable {
        package var currentQuality: String
        package var oldPaths: [String]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case currentQuality = "current_quality"
            case oldPaths = "old_paths"
        }

        package init(currentQuality: String, oldPaths: [String]) {
            self.currentQuality = currentQuality
            self.oldPaths = oldPaths
        }

        package init(from decoder: any Decoder) throws {
            let container = try strictContainer(decoder, CodingKeys.self)
            currentQuality = try container.decode(String.self, forKey: .currentQuality)
            oldPaths = try container.decode([String].self, forKey: .oldPaths)
        }
    }

    /// Never reused.
    package var id: Int
    /// The store's revision when the job last changed; it only grows.
    package var revision: Int
    package var source: Source
    package var formatPolicy: FormatPolicy
    package var release: Release
    package var state: JobState
    /// Set with `failed` only.
    package var failedStage: FailedStage?
    /// One line for the window: why it's `not_found`, failed or cancelled. A `not_found`
    /// job's stays through its next search, until that attempt ends.
    package var reason: String?
    /// Search attempts so far, from 1.
    package var attempt: Int
    /// With `not_found`, when the next search runs; nil after the last automatic attempt.
    package var nextAttemptAt: Int?
    package var progress: Progress?
    /// Set with `searching` only, once its first query has started.
    package var search: Search?
    package var candidate: Candidate?
    /// In release order; empty until a candidate is chosen.
    package var files: [File]
    /// From `staged` on: the job's folder in the staging folder, one component, as the service
    /// sent it. Read it through `stagedFolder`, which refuses any other.
    package var stagedPath: String?

    /// `stagedPath` when it's the one folder name the contract promises; nil before the job is
    /// staged, and for a path with a `/` or that is empty, `.` or `..`, which would name a
    /// folder outside the staging folder.
    package var stagedFolder: String? {
        guard let path = stagedPath, !path.isEmpty, path != ".", path != "..",
            !path.contains("/")
        else { return nil }
        return path
    }

    /// Why a `stagedPath` that `stagedFolder` refuses isn't used.
    package static func notOneFolder(_ path: String) -> String {
        "the service's staged folder \(path.debugDescription) isn't one folder name in the"
            + " staging folder"
    }
    package var tagging: Tagging
    package var lease: Hold?
    package var review: Hold?
    /// Set for `source` `upgrade` only.
    package var upgrade: Upgrade?
    /// Whether a rejected or cancelled job's files are still being deleted.
    var cleanupPending: Bool
    package var createdAt: Int
    package var updatedAt: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, revision, source
        case formatPolicy = "format_policy"
        case release, state
        case failedStage = "failed_stage"
        case reason, attempt
        case nextAttemptAt = "next_attempt_at"
        case progress, search, candidate, files
        case stagedPath = "staged_path"
        case tagging, lease, review, upgrade
        case cleanupPending = "cleanup_pending"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        revision = try container.decode(Int.self, forKey: .revision)
        source = try container.decode(Source.self, forKey: .source)
        formatPolicy = try container.decode(FormatPolicy.self, forKey: .formatPolicy)
        release = try container.decode(Release.self, forKey: .release)
        state = try container.decode(JobState.self, forKey: .state)
        failedStage = try container.decode(FailedStage?.self, forKey: .failedStage)
        reason = try container.decode(String?.self, forKey: .reason)
        attempt = try container.decode(Int.self, forKey: .attempt)
        nextAttemptAt = try container.decode(Int?.self, forKey: .nextAttemptAt)
        progress = try container.decode(Progress?.self, forKey: .progress)
        search = try container.decode(Search?.self, forKey: .search)
        candidate = try container.decode(Candidate?.self, forKey: .candidate)
        files = try container.decode([File].self, forKey: .files)
        stagedPath = try container.decode(String?.self, forKey: .stagedPath)
        tagging = try container.decode(Tagging.self, forKey: .tagging)
        lease = try container.decode(Hold?.self, forKey: .lease)
        review = try container.decode(Hold?.self, forKey: .review)
        upgrade = try container.decode(Upgrade?.self, forKey: .upgrade)
        cleanupPending = try container.decode(Bool.self, forKey: .cleanupPending)
        createdAt = try container.decode(Int.self, forKey: .createdAt)
        updatedAt = try container.decode(Int.self, forKey: .updatedAt)
    }
}

/// The reply of every route that changes a job: the job as it now is.
package struct JobReply: Decodable {
    var job: DownloadJob

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ok, job
    }

    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        job = try container.decode(DownloadJob.self, forKey: .job)
    }
}
