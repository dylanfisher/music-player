import Foundation
import Testing

@testable import HALOutput
@testable import Playback

/// A file under a volume that isn't mounted names the volume; one missing elsewhere, or from a
/// folder that's there, is just missing; one that's there is no error.
@Test func aMissingFileNamesItsVolumeWhenTheVolumeIsntMounted() throws {
    let volumes = FileManager.default.temporaryDirectory.appendingPathComponent(
        "volumes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: volumes) }
    let track = volumes.appendingPathComponent("music/library/a.flac")

    let unmounted = try #require(MissingFileError(track, volumes: volumes.path))
    #expect(unmounted.unmountedVolume == "music")
    #expect(unmounted.userMessage == "the volume “music” isn't mounted")

    // A share that's gone can leave an empty folder on the startup disk.
    try FileManager.default.createDirectory(
        at: track.deletingLastPathComponent(), withIntermediateDirectories: true)
    #expect(MissingFileError(track, volumes: volumes.path)?.unmountedVolume == "music")

    #expect(MissingFileError(track, volumes: "/Volumes")?.userMessage == "the file is missing")
    try Data().write(to: track)
    #expect(MissingFileError(track, volumes: volumes.path) == nil)
}

/// A track whose file is gone fails as missing, not as one macOS can't decode.
@Test func aTrackWhoseFileIsGoneFailsAsMissing() async throws {
    let stepped = try Stepped()
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-\(UUID()).flac")
    stepped.output.load(OutputItem(id: 1, url: missing), startSeconds: 0, playing: true)
    stepped.step()
    while true {
        guard case .trackFailed(1, let error) = try await stepped.events.next() else { continue }
        #expect((error as? MissingFileError)?.userMessage == "the file is missing")
        return
    }
}
