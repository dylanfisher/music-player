import Foundation
import Testing

@testable import Recommender

// The paths the service names in a job, checked where the job is read (ADR 0025, rows 67 and
// 68): a staged file's name inside the job's folder, an upgrade's old path inside the share.

/// The contract's example job with its files named `names` and its folder `stagedPath`.
private func job(names: [String], stagedPath: String? = "job-42") throws -> DownloadJob {
    let files = names.map { #"{"name": \#(quoted($0)), "size": 1, "position": null}"# }
    let text = try fixture("job.json")
        .replacingOccurrences(
            of: #""files": \[[^\]]*\]"#,
            with: NSRegularExpression.escapedTemplate(
                for: #""files": [\#(files.joined(separator: ", "))]"#),
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #""staged_path": "job-42""#,
            with: #""staged_path": \#(stagedPath.map(quoted) ?? "null")"#)
    return try replyDecoder.decode(DownloadJob.self, from: Data(text.utf8))
}

private func quoted(_ text: String) -> String {
    String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
}

@Test func aPathIsInsideItsFolderOnlyWhenRelativeWithNoDotParts() {
    for inside in ["a.flac", "CD1/01.flac", "..a", "a..", ".hidden"] {
        #expect(isRelativeInside(inside), "\(inside)")
    }
    for outside in ["", "/etc/x", "../x.flac", "a/../../x", "a//b", "./a", "a/.", "a/", ".."] {
        #expect(!isRelativeInside(outside), "\(outside)")
    }
}

@Test func aStagedJobsFilesAreItsOnlyWhenEveryNameIsInsideItsFolder() throws {
    let staged = try job(names: ["01.flac", "CD2/01.flac"])
    #expect(staged.stagedFiles?.map(\.name) == ["01.flac", "CD2/01.flac"])
    #expect(staged.stagedProblem == nil)
    for name in ["../x.flac", "/etc/x", "a/../../x.flac"] {
        let hostile = try job(names: ["01.flac", name])
        #expect(hostile.stagedFiles == nil, "\(name)")
        #expect(hostile.stagedProblem?.contains(name.debugDescription) == true)
        #expect(hostile.stagedProblem?.hasSuffix("isn't a path inside the job's folder") == true)
        // The job itself still reads, so the window can show it.
        #expect(hostile.files.count == 2)
    }
}

@Test func aJobNotYetStagedHasNoStagedFilesWhateverItsPeerNamedThem() throws {
    let remote = try job(names: [#"@@share\Music\..\x.flac"#, "../x.flac"], stagedPath: nil)
    #expect(remote.files.count == 2)
    #expect(remote.stagedFiles == nil)
    #expect(remote.stagedProblem == nil)
}

@Test func aStagedFolderOutsideTheStagingFolderHasNoStagedFiles() throws {
    let outside = try job(names: ["01.flac"], stagedPath: "../library")
    #expect(outside.stagedFiles == nil)
    #expect(outside.stagedProblem == DownloadJob.notOneFolder("../library"))
}

@Test func anUpgradesOldPathOutsideTheShareFailsTheDecode() throws {
    let upgrade = { (path: String) in
        #"{"current_quality": "MP3 320", "old_paths": ["library/a.mp3", \#(quoted(path))]}"#
    }
    #expect(
        try replyDecoder.decode(DownloadJob.Upgrade.self, from: Data(upgrade("library/b.mp3").utf8))
            .oldPaths == ["library/a.mp3", "library/b.mp3"])
    for path in ["../elsewhere.flac", "library/../../x.flac", "/Volumes/music/x.flac", ""] {
        #expect(throws: DecodingError.self, "\(path)") {
            try replyDecoder.decode(DownloadJob.Upgrade.self, from: Data(upgrade(path).utf8))
        }
    }
}
