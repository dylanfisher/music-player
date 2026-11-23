import AppKit
import Metadata
import Recommender
import Settings

extension Downloads {
    static let noStagingFolder = "The staging folder wasn't found"

    /// Shows the staged folders of `jobs` in the Finder together, found where the staging
    /// folder is now. A folder the service names outside the staging folder, by its name or
    /// by a link, is refused, and the others shown.
    func reveal(_ jobs: [DownloadJob], _ session: Session) {
        var folders: [String] = []
        var problems: [String] = []
        for job in jobs {
            guard let path = job.stagedPath else { continue }
            guard let folder = job.stagedFolder else {
                problems.append(DownloadJob.notOneFolder(path))
                continue
            }
            folders.append(folder)
        }
        let places = session.setup.places
        Task {
            var urls: [URL] = []
            if !folders.isEmpty {
                let root: String
                do {
                    root = try await places().stagingRoot
                } catch {
                    return alert(Self.noStagingFolder, ["\(error)"] + problems)
                }
                for folder in folders {
                    let url = URL(fileURLWithPath: root, isDirectory: true)
                        .appendingPathComponent(folder, isDirectory: true)
                    if let found = await Self.outsideStaging(url, root) {
                        problems.append(found)
                    } else {
                        urls.append(url)
                    }
                }
            }
            if !urls.isEmpty { showInFinder(urls) }
            if !problems.isEmpty {
                alert(
                    problems.count == 1
                        ? "The staged folder wasn't shown"
                        : "\(problems.count) staged folders weren't shown", problems)
            }
        }
    }

    /// Why `url`, a staged folder, can't be shown: it's missing, or it leads outside the
    /// staging folder at `root`. Nil when it can.
    private nonisolated static func outsideStaging(_ url: URL, _ root: String) async -> String? {
        await blockingFileWork { () -> String? in
            guard FileManager.default.fileExists(atPath: url.path) else {
                return "\(url.path) is missing"
            }
            let real = url.resolvingSymlinksInPath().path
            let realRoot = URL(fileURLWithPath: root, isDirectory: true)
                .resolvingSymlinksInPath().path
            return isPath(real, inOrAt: realRoot) && real != realRoot
                ? nil : "\(url.path) leads outside the staging folder, to \(real)"
        }
    }
}
