/// A download job as the service reports it, whole, as it is now. Times are seconds since 1970.
package struct DownloadJob: Equatable, Sendable, Decodable {
    /// How the job was made.
    enum Source: String, Equatable, Sendable, Codable {
        case manual, upgrade, recommendation
    }

    /// The step a `failed` job failed at.
    enum FailedStage: String, Equatable, Sendable, Codable {
        case search, download, stage, tag, move, delete, carry
    }

    /// The release, from the snapshot it was made with.
    struct Release: Equatable, Sendable, Decodable {
        var releaseID: Int
        var artist: String
        var title: String
        var year: Int?

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

        init(from decoder: any Decoder) throws {
            let container = try strictContainer(decoder, CodingKeys.self)
            releaseID = try container.decode(Int.self, forKey: .releaseID)
            artist = try container.decode(String.self, forKey: .artist)
            title = try container.decode(String.self, forKey: .title)
            year = try container.decode(Int?.self, forKey: .year)
        }
    }

    /// A `downloading` job's transfers so far.
    struct Progress: Equatable, Sendable, Decodable {
        var filesDone: Int
        var filesTotal: Int
        var bytesDone: Int
        var bytesTotal: Int

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case filesDone = "files_done"
            case filesTotal = "files_total"
            case bytesDone = "bytes_done"
            case bytesTotal = "bytes_total"
        }

        init(from decoder: any Decoder) throws {
            let container = try strictContainer(decoder, CodingKeys.self)
            filesDone = try container.decode(Int.self, forKey: .filesDone)
            filesTotal = try container.decode(Int.self, forKey: .filesTotal)
            bytesDone = try container.decode(Int.self, forKey: .bytesDone)
            bytesTotal = try container.decode(Int.self, forKey: .bytesTotal)
        }
    }

    /// The Soulseek folder chosen, as its peer reported it.
    package struct Candidate: Equatable, Sendable, Decodable {
        package enum Format: String, Equatable, Sendable, Decodable {
            case flac, alac, mp3, ogg, opus, wav, ape, wv
        }

        /// The Soulseek user.
        var peer: String
        var format: Format
        var bitDepth: Int?
        var sampleRateHz: Int?
        var bitrateKbps: Int?
        var variableBitrate: Bool?
        var fileCount: Int
        var bytes: Int
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
    struct Tagging: Equatable, Sendable, Decodable {
        enum Status: String, Equatable, Sendable, Codable {
            case none, running, clean, discrepancy, error
        }

        var status: Status
        /// Empty unless `discrepancy` or `error`.
        var reasons: [String]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case status, reasons
        }

        init(status: Status, reasons: [String]) {
            self.status = status
            self.reasons = reasons
        }

        init(from decoder: any Decoder) throws {
            let container = try strictContainer(decoder, CodingKeys.self)
            status = try container.decode(Status.self, forKey: .status)
            reasons = try container.decode([String].self, forKey: .reasons)
        }
    }

    /// A live tagging lease or review claim: whose, and until when.
    struct Hold: Equatable, Sendable, Decodable {
        var machine: String
        var expiresAt: Int

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case machine
            case expiresAt = "expires_at"
        }

        init(machine: String, expiresAt: Int) {
            self.machine = machine
            self.expiresAt = expiresAt
        }

        init(from decoder: any Decoder) throws {
            let container = try strictContainer(decoder, CodingKeys.self)
            machine = try container.decode(String.self, forKey: .machine)
            expiresAt = try container.decode(Int.self, forKey: .expiresAt)
        }
    }

    /// What an upgrade replaces: the old album's quality, for the window, and its files,
    /// relative to the library share, so they resolve on any Mac and after an index rebuild.
    struct Upgrade: Equatable, Sendable, Codable {
        var currentQuality: String
        var oldPaths: [String]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case currentQuality = "current_quality"
            case oldPaths = "old_paths"
        }

        init(currentQuality: String, oldPaths: [String]) {
            self.currentQuality = currentQuality
            self.oldPaths = oldPaths
        }

        init(from decoder: any Decoder) throws {
            let container = try strictContainer(decoder, CodingKeys.self)
            currentQuality = try container.decode(String.self, forKey: .currentQuality)
            oldPaths = try container.decode([String].self, forKey: .oldPaths)
        }
    }

    /// Never reused.
    var id: Int
    /// The store's revision when the job last changed; it only grows.
    package var revision: Int
    var source: Source
    var formatPolicy: FormatPolicy
    var release: Release
    var state: JobState
    /// Set with `failed` only.
    var failedStage: FailedStage?
    /// One line for the window: why it's `not_found`, failed or cancelled.
    var reason: String?
    /// Search attempts so far, from 1.
    var attempt: Int
    var nextAttemptAt: Int?
    var progress: Progress?
    var candidate: Candidate?
    /// In release order; empty until a candidate is chosen.
    var files: [File]
    /// From `staged` on: the job's folder in the staging folder, one component.
    var stagedPath: String?
    var tagging: Tagging
    var lease: Hold?
    var review: Hold?
    /// Set for `source` `upgrade` only.
    var upgrade: Upgrade?
    /// Whether a rejected or cancelled job's files are still being deleted.
    var cleanupPending: Bool
    var createdAt: Int
    var updatedAt: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, revision, source
        case formatPolicy = "format_policy"
        case release, state
        case failedStage = "failed_stage"
        case reason, attempt
        case nextAttemptAt = "next_attempt_at"
        case progress, candidate, files
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
